-- host.lua
-- The only module that touches Juju / Roblox globals directly. Everything else receives the
-- adapter built here, which (a) probes capabilities, (b) validates every value coming back from
-- the host, (c) guarantees the addon stays read-only towards Juju (flags: jhc_* only).

local U = require("util")

local H = {}

H.FLAG_PREFIX = "jhc_"

-- Globals the addon looks at. Built lazily so tests can pass their own environment table.
function H.default_env()
  return {
    juju = juju, game = game, task = task, Drawing = Drawing,
    Vector2 = Vector2, Color3 = Color3, Instance = Instance, print = print, warn = warn,
    getgenv = getgenv, typeof = typeof, os_clock = os and os.clock or nil,
    shared = _G,
  }
end

local JUJU_FUNCTIONS = {
  "create_tab", "create_section", "create_element", "find_element", "set_tab_text",
  "create_connection", "on_unload", "get_signal", "get_signals",
  "get_flag", "set_flag", "get_flags", "get_ragebot_target", "get_ragebot_targets",
  "get_ping", "get_server_cframe", "get_client_cframe",
}

-- Returns host, nil on success; nil, "reason" when the addon cannot run at all.
function H.detect(env)
  if type(env) ~= "table" then return nil, "no environment table" end
  local juju_t = env.juju
  if type(juju_t) ~= "table" then
    return nil, "global 'juju' not found - this addon must be executed by Juju"
  end
  if type(juju_t.on_unload) ~= "function" then
    return nil, "juju.on_unload missing - refusing to run without a cleanup hook"
  end
  if env.game == nil then return nil, "global 'game' not found" end
  local tk = env.task
  if type(tk) ~= "table" or type(tk.spawn) ~= "function" or type(tk.delay) ~= "function" then
    return nil, "task.spawn / task.delay missing"
  end
  local ok_p, players = pcall(function() return env.game:GetService("Players") end)
  if not ok_p or players == nil then return nil, "Players service unavailable" end
  local clock = env.os_clock
  if type(clock) ~= "function" then return nil, "no monotonic clock (os.clock) available" end

  local host = {
    env = env, juju = juju_t, task = tk, players = players, clock = clock,
    caps = {}, errors = 0, invalid_pings = 0, refused_flag_writes = 0,
  }
  for i = 1, #JUJU_FUNCTIONS do
    local n = JUJU_FUNCTIONS[i]
    host.caps[n] = type(juju_t[n]) == "function"
  end
  host.caps.drawing = type(env.Drawing) == "table" and type(env.Drawing.new) == "function"
  host.caps.task_cancel = type(tk.cancel) == "function"
  host.caps.task_wait = type(tk.wait) == "function"

  local print_fn = env.print
  host.say = function(msg)
    if type(print_fn) == "function" then pcall(print_fn, "[JHC] " .. tostring(msg)) end
  end

  function host.local_player()
    local ok, lp = pcall(function() return host.players.LocalPlayer end)
    if ok then return lp end
    return nil
  end

  -- Managed connection. juju.create_connection (documented: auto-disconnects on unload) is tried
  -- first. LIVE FINDING: called from a script that is not loaded as a Juju addon it returned nil
  -- and connected NOTHING. So a result that is not a real connection object is treated as "did not
  -- connect" and the signal is connected directly; this addon's own unload hook disconnects it.
  host.connect_fallbacks = 0
  function host.connect(signal, fn)
    if type(signal) == "table" and signal.__direct then return signal:Connect(fn) end   -- Juju custom signal
    if host.caps.create_connection then
      local ok, conn = pcall(juju_t.create_connection, signal, fn)
      if ok and conn ~= nil then
        local okd, d = pcall(function() return conn.Disconnect end)
        if okd and d ~= nil then return conn end
      end
      host.connect_fallbacks = host.connect_fallbacks + 1
    end
    return signal:Connect(fn)
  end

  -- One-time, asynchronous check of what juju.create_connection really does here, using a
  -- throwaway BindableEvent. Result in host.connect_behaviour:
  --   returns_connection   documented behaviour
  --   noop_returns_nil     does nothing (seen when not loaded as a Juju addon): fallback is correct
  --   connects_returns_nil connects but hands back nothing: the fallback may double-connect (warned)
  --   errors               raised an error
  function host.probe_connect(on_done)
    local I = env.Instance
    if not (host.caps.create_connection and type(I) == "table" and type(I.new) == "function"
            and host.caps.task_wait) then
      return
    end
    pcall(host.task.spawn, function()
      local okb, be = pcall(I.new, "BindableEvent")
      if not okb or be == nil then return end
      local fired = 0
      local ok, conn = pcall(juju_t.create_connection, be.Event, function() fired = fired + 1 end)
      pcall(function() be:Fire() end)
      host.task.wait(0.1)
      local mode
      if not ok then
        mode = "errors"
      elseif conn ~= nil and fired > 0 then
        mode = "returns_connection"
      elseif conn ~= nil then
        mode = "returns_connection_but_silent"
      elseif fired > 0 then
        mode = "connects_returns_nil"
        host.dup_risk = true
      else
        mode = "noop_returns_nil"
      end
      if conn ~= nil then pcall(function() conn:Disconnect() end) end
      pcall(function() be:Destroy() end)
      host.connect_behaviour = mode
      if on_done then pcall(on_done, mode) end
    end)
  end

  function host.ping()
    if not host.caps.get_ping then return nil end
    local ok, v = pcall(juju_t.get_ping)
    if not ok then host.errors = host.errors + 1; return nil end
    if not U.is_finite(v) or v <= 0 or v > 1e6 then
      host.invalid_pings = host.invalid_pings + 1
      return nil
    end
    return v
  end

  -- |server - client| position of the local HumanoidRootPart (documented get_*_cframe pair).
  function host.gap()
    if not (host.caps.get_server_cframe and host.caps.get_client_cframe) then return nil end
    local ok, d = pcall(function()
      local s = juju_t.get_server_cframe()
      local c = juju_t.get_client_cframe()
      return (s.Position - c.Position).Magnitude
    end)
    if ok and U.is_finite(d) then return d end
    return nil
  end

  -- Juju custom signal by name (documented get_signal), or nil. Wrapped so host.connect connects it
  -- directly (create_connection is documented for RBXScriptSignals).
  function host.juju_signal(name)
    if not host.caps.get_signal then return nil end
    local ok, sig = pcall(juju_t.get_signal, name)
    if not ok or sig == nil then return nil end
    local okc, c = pcall(function() return sig.Connect end)
    if not okc or c == nil then return nil end
    return { __direct = true, Connect = function(_, fn) return sig:Connect(fn) end }
  end

  function host.get_flag(name)
    if not host.caps.get_flag then return nil end
    local ok, v = pcall(juju_t.get_flag, name)
    if ok then return v end
    host.errors = host.errors + 1
    return nil
  end

  -- Hard read-only guard: only jhc_* flags can ever be written.
  function host.set_flag(name, value)
    if not host.caps.set_flag then return false, "set_flag unavailable" end
    if type(name) ~= "string" or string.sub(name, 1, #H.FLAG_PREFIX) ~= H.FLAG_PREFIX then
      host.refused_flag_writes = host.refused_flag_writes + 1
      return false, "refused: flag outside jhc_ namespace"
    end
    local ok = pcall(juju_t.set_flag, name, value)
    if not ok then host.errors = host.errors + 1; return false, "set_flag failed" end
    return true
  end

  function host.flag_names()
    if not host.caps.get_flags then return {} end
    local ok, v = pcall(juju_t.get_flags)
    if ok and type(v) == "table" then return v end
    return {}
  end

  function host.ragebot_target()
    if not host.caps.get_ragebot_target then return nil end
    local ok, p = pcall(juju_t.get_ragebot_target)
    if ok and p ~= nil then return p end
    return nil
  end

  function host.ragebot_on()
    local v = host.get_flag("ragebot")
    if v == nil then return nil end
    return v and true or false
  end

  -- Shared table for the duplicate-load guard (executor getgenv() when present, else _G).
  function host.registry()
    local ok, g = pcall(function()
      if type(env.getgenv) == "function" then return env.getgenv() end
      return nil
    end)
    if ok and type(g) == "table" then return g end
    if type(env.shared) == "table" then return env.shared end
    H._fallback_registry = H._fallback_registry or {}
    return H._fallback_registry
  end

  -- Human readable capability matrix for the report.
  function host.caps_lines()
    local lines = {}
    local names = {}
    for k in pairs(host.caps) do names[#names + 1] = k end
    table.sort(names)
    for i = 1, #names do
      lines[#lines + 1] = string.format("  %-22s %s", names[i], host.caps[names[i]] and "yes" or "NO")
    end
    return lines
  end

  return host, nil
end

return H
