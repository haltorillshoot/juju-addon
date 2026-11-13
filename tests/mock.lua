-- tests/mock.lua
-- SIMULATED environment: virtual clock + scheduler, Roblox instance/signal mocks, and a STRICT
-- Juju mock that enforces the documented signatures (and raises on anything undocumented the
-- addon might try). Everything here is built from the docs and standard Roblox semantics; it is
-- NOT the real game. Results obtained with it are labelled SIMULATED in the report.

local M = {}

-- ---------------------------------------------------------------------------------------
-- Virtual time + scheduler (task.spawn / delay / wait / cancel)
-- ---------------------------------------------------------------------------------------
local Sim = {}
Sim.__index = Sim
M.Sim = Sim

function Sim.new()
  local s = setmetatable({ t = 0, timers = {}, seq = 0, errors = {}, dead = {},
    stats = { spawns = 0, delays = 0, waits = 0, cancels = 0, fired = 0 } }, Sim)
  s.clock = function() return s.t end
  s.task = {}
  s.task.spawn = function(fn, ...)
    s.stats.spawns = s.stats.spawns + 1
    local co = coroutine.create(fn)
    s:_resume(co, ...)
    return co
  end
  s.task.delay = function(sec, fn, ...)
    s.stats.delays = s.stats.delays + 1
    assert(type(sec) == "number", "task.delay: seconds must be a number")
    assert(type(fn) == "function", "task.delay: callback must be a function")
    local args = { ... }
    local handle = { kind = "delay" }
    s:_add(sec, function() fn(unpack(args)) end, handle)
    return handle
  end
  s.task.wait = function(sec)
    s.stats.waits = s.stats.waits + 1
    local co = coroutine.running()
    assert(co, "task.wait called outside a coroutine")
    s:_add(sec or 0, function() s:_resume(co) end, co)
    coroutine.yield()
    return sec or 0
  end
  s.task.cancel = function(h)
    s.stats.cancels = s.stats.cancels + 1
    if type(h) == "thread" then
      s.dead[h] = true
    end
    for i = 1, #s.timers do
      if s.timers[i].owner == h then s.timers[i].cancelled = true end
    end
  end
  return s
end

function Sim:_resume(co, ...)
  if self.dead[co] or coroutine.status(co) == "dead" then return end
  local ok, err = coroutine.resume(co, ...)
  if not ok then self.errors[#self.errors + 1] = tostring(err) end
end

-- drop cancelled timers (and timers of cancelled threads) so the scheduler itself cannot leak
function Sim:_compact()
  local keep = {}
  for i = 1, #self.timers do
    local x = self.timers[i]
    local owner_dead = type(x.owner) == "thread" and self.dead[x.owner]
    if not x.cancelled and not owner_dead then keep[#keep + 1] = x end
  end
  self.timers = keep
end

function Sim:_add(sec, fn, owner)
  self.seq = self.seq + 1
  self.timers[#self.timers + 1] = { when = self.t + sec, seq = self.seq, fn = fn, owner = owner }
  if #self.timers > 128 and self.seq % 64 == 0 then self:_compact() end
end

function Sim:pending_timers()
  local n = 0
  for i = 1, #self.timers do
    if not self.timers[i].cancelled and not (type(self.timers[i].owner) == "thread" and self.dead[self.timers[i].owner]) then
      n = n + 1
    end
  end
  return n
end

-- earliest due timer with when <= limit, or nil
function Sim:_next(limit)
  local best, bi
  for i = 1, #self.timers do
    local x = self.timers[i]
    if not x.cancelled and x.when <= limit then
      if not best or x.when < best.when or (x.when == best.when and x.seq < best.seq) then best, bi = x, i end
    end
  end
  return best, bi
end

-- Advance time smoothly: timers fire at their own due time.
function Sim:advance(dt)
  local target = self.t + dt
  while true do
    local x, i = self:_next(target)
    if not x then break end
    table.remove(self.timers, i)
    if x.when > self.t then self.t = x.when end
    self.stats.fired = self.stats.fired + 1
    local ok, err = pcall(x.fn)
    if not ok then self.errors[#self.errors + 1] = tostring(err) end
  end
  self.t = target
end

-- Client freeze: the clock jumps, then everything that became due runs LATE, in order.
function Sim:freeze(dt)
  self.t = self.t + dt
  while true do
    local x, i = self:_next(self.t)
    if not x then break end
    table.remove(self.timers, i)
    self.stats.fired = self.stats.fired + 1
    local ok, err = pcall(x.fn)
    if not ok then self.errors[#self.errors + 1] = tostring(err) end
  end
end

-- ---------------------------------------------------------------------------------------
-- Signals
-- ---------------------------------------------------------------------------------------
local Signal = {}
Signal.__index = Signal
M.Signal = Signal
Signal.live_total = 0      -- all currently connected handlers, globally (leak detector)
Signal.handler_errors = {}

function Signal.new(name)
  return setmetatable({ name = name or "signal", handlers = {}, live = 0 }, Signal)
end

function Signal:Connect(fn)
  assert(type(fn) == "function", "Connect: handler must be a function")
  local conn = { Connected = true, signal = self, fn = fn }
  function conn:Disconnect()
    if not self.Connected then return end
    self.Connected = false
    local hs = self.signal.handlers
    for i = 1, #hs do
      if hs[i] == self then table.remove(hs, i) break end
    end
    self.signal.live = self.signal.live - 1
    Signal.live_total = Signal.live_total - 1
  end
  self.handlers[#self.handlers + 1] = conn
  self.live = self.live + 1
  Signal.live_total = Signal.live_total + 1
  return conn
end

function Signal:Fire(...)
  local snapshot = {}
  for i = 1, #self.handlers do snapshot[i] = self.handlers[i] end
  for i = 1, #snapshot do
    local c = snapshot[i]
    if c.Connected then
      local ok, err = pcall(c.fn, ...)
      if not ok then Signal.handler_errors[#Signal.handler_errors + 1] = tostring(err) end
    end
  end
end

-- ---------------------------------------------------------------------------------------
-- Vector3 / CFrame (just what the addon touches)
-- ---------------------------------------------------------------------------------------
local V3 = {}
V3.__index = function(t, k)
  if k == "Magnitude" then return math.sqrt(t.X * t.X + t.Y * t.Y + t.Z * t.Z) end
  return rawget(V3, k)
end
V3.__sub = function(a, b) return M.Vector3(a.X - b.X, a.Y - b.Y, a.Z - b.Z) end
function M.Vector3(x, y, z) return setmetatable({ X = x, Y = y, Z = z }, V3) end

-- ---------------------------------------------------------------------------------------
-- Instances
-- ---------------------------------------------------------------------------------------
local PARENT_CLASS = { Tool = "Instance", Humanoid = "Instance", IntValue = "ValueBase",
  NumberValue = "ValueBase", StringValue = "ValueBase", ValueBase = "Instance", Model = "Instance",
  Backpack = "Instance", Folder = "Instance", Part = "Instance" }

local Inst = {}
Inst.__index = Inst
M.Instance = Inst

function Inst.new(class, name)
  local o = setmetatable({ ClassName = class, Name = name or class, Parent = nil, _kids = {}, _attrs = {},
    _attr_sigs = {}, ChildAdded = Signal.new("ChildAdded"), ChildRemoved = Signal.new("ChildRemoved"),
    AncestryChanged = Signal.new("AncestryChanged"), Destroying = Signal.new("Destroying") }, Inst)
  if class == "Tool" then
    o.Activated = Signal.new("Activated"); o.Equipped = Signal.new("Equipped"); o.Unequipped = Signal.new("Unequipped")
    o.Enabled = true
  elseif class == "Humanoid" then
    o.HealthChanged = Signal.new("HealthChanged"); o.Died = Signal.new("Died")
    o.Health = 100; o.MaxHealth = 100
  elseif class == "IntValue" or class == "NumberValue" then
    o.Changed = Signal.new("Changed"); o.Value = 0
  end
  return o
end

function Inst:IsA(cls)
  local c = self.ClassName
  while c do
    if c == cls then return true end
    c = PARENT_CLASS[c]
  end
  return cls == "Instance"
end

function Inst:GetChildren()
  local r = {}
  for i = 1, #self._kids do r[i] = self._kids[i] end
  return r
end

function Inst:FindFirstChild(name)
  for i = 1, #self._kids do if self._kids[i].Name == name then return self._kids[i] end end
  return nil
end

function Inst:FindFirstChildOfClass(cls)
  for i = 1, #self._kids do if self._kids[i].ClassName == cls then return self._kids[i] end end
  return nil
end

function Inst:SetParent(p)
  local old = self.Parent
  if old == p then return end
  if old then
    for i = 1, #old._kids do
      if old._kids[i] == self then table.remove(old._kids, i) break end
    end
  end
  self.Parent = p
  if old then old.ChildRemoved:Fire(self) end
  if p then
    p._kids[#p._kids + 1] = self
    p.ChildAdded:Fire(self)
  end
  self.AncestryChanged:Fire(self, p)
end

function Inst:Destroy()
  self.Destroying:Fire()
  self:SetParent(nil)
end

function Inst:SetAttribute(n, v)
  self._attrs[n] = v
  if self._attr_sigs[n] then self._attr_sigs[n]:Fire() end
end
function Inst:GetAttribute(n) return self._attrs[n] end
function Inst:GetAttributes()
  local r = {}
  for k, v in pairs(self._attrs) do r[k] = v end
  return r
end
function Inst:GetAttributeChangedSignal(n)
  if not self._attr_sigs[n] then self._attr_sigs[n] = Signal.new("attr:" .. n) end
  return self._attr_sigs[n]
end

-- test drivers (not Roblox API)
function Inst:SetHealth(h)
  local old = self.Health
  self.Health = h
  self.HealthChanged:Fire(h)
  if h <= 0 and old > 0 then self.Died:Fire() end
end
function Inst:SetValue(v)
  self.Value = v
  self.Changed:Fire(v)
end

-- ---------------------------------------------------------------------------------------
-- Game: Players + characters + tools
-- ---------------------------------------------------------------------------------------
local Game = {}
Game.__index = Game
M.Game = Game

function Game.new(sim)
  local g = setmetatable({ sim = sim, players = {}, PlayerAdded = Signal.new("PlayerAdded"),
    PlayerRemoving = Signal.new("PlayerRemoving"), heartbeat = Signal.new("Heartbeat") }, Game)
  g.Players = { PlayerAdded = g.PlayerAdded, PlayerRemoving = g.PlayerRemoving, LocalPlayer = nil }
  function g.Players:GetPlayers()
    local r = {}
    for i = 1, #g.players do r[i] = g.players[i] end
    return r
  end
  g.game = {}
  function g.game:GetService(name)
    if name == "Players" then return g.Players end
    if name == "RunService" then return { Heartbeat = g.heartbeat } end
    error("unknown service " .. tostring(name))
  end
  return g
end

function Game:add_player(name, uid, is_local)
  local p = { Name = name, UserId = uid, Character = nil, CharacterAdded = Signal.new("CharacterAdded"),
    CharacterRemoving = Signal.new("CharacterRemoving"), backpack = Inst.new("Backpack", "Backpack") }
  self.players[#self.players + 1] = p
  if is_local then self.Players.LocalPlayer = p end
  if not is_local or self.announce_local then self.PlayerAdded:Fire(p) end
  return p
end

function Game:remove_player(p)
  self.PlayerRemoving:Fire(p)
  for i = 1, #self.players do
    if self.players[i] == p then table.remove(self.players, i) break end
  end
  if p.Character then p.Character:Destroy(); p.Character = nil end
end

-- spawn a character; opts.late_humanoid delays the Humanoid until after the model
function Game:spawn(p, opts)
  opts = opts or {}
  local model = Inst.new("Model", p.Name)
  local hum
  if not opts.late_humanoid then
    hum = Inst.new("Humanoid", "Humanoid")
    hum.Health = opts.health or 100
    hum:SetParent(model)
  end
  p.Character = model
  p.CharacterAdded:Fire(model)
  p.hum = hum
  return model, hum
end

function Game:add_humanoid_late(p, health)
  local hum = Inst.new("Humanoid", "Humanoid")
  hum.Health = health or 100
  hum:SetParent(p.Character)
  p.hum = hum
  return hum
end

function Game:despawn(p)
  p.CharacterRemoving:Fire(p.Character)
  local c = p.Character
  p.Character = nil
  if c then c:Destroy() end
  p.hum = nil
end

-- create a tool in the player's backpack. opts.ammo = starting ammo (IntValue "Ammo") ; opts.attr_ammo
function Game:give_tool(p, name, opts)
  opts = opts or {}
  local tool = Inst.new("Tool", name)
  if opts.ammo then
    local a = Inst.new("IntValue", opts.ammo_name or "Ammo")
    a.Value = opts.ammo
    a:SetParent(tool)
    tool.ammo = a
  end
  if opts.max_ammo then
    local a = Inst.new("IntValue", "MaxAmmo")
    a.Value = opts.max_ammo
    a:SetParent(tool)
  end
  if opts.attr_ammo then tool:SetAttribute("Ammo", opts.attr_ammo) end
  tool:SetParent(p.backpack)
  return tool
end

function Game:equip(p, tool)
  tool:SetParent(p.Character)
  tool.Equipped:Fire()
end

function Game:unequip(p, tool)
  tool:SetParent(p.backpack)
  tool.Unequipped:Fire()
end

-- ---------------------------------------------------------------------------------------
-- Strict Juju mock (documented API only)
-- ---------------------------------------------------------------------------------------
local RESERVED = { author = true, date = true, loaded_addons = true }

function M.new_juju(sim, game)
  local J = { calls = {}, flags = {}, sections = {}, elements = {}, tabs = 0, tab_text = nil,
    unload_cbs = {}, managed = {}, ping = 60, ragebot_target = nil, server_pos = M.Vector3(0, 0, 0),
    client_pos = M.Vector3(0, 0, 0), violations = {}, strict_errors = {}, throw = {} }
  J.signals = { on_ragebot_target_changed = Signal.new("a"), on_legitbot_target_changed = Signal.new("b"),
    on_target_changed = Signal.new("c"), on_player_status_changed = Signal.new("d") }
  local api = {}
  J.api = api

  J.record = true
  local function rec(name, ...)
    if J.record then J.calls[#J.calls + 1] = { name = name, args = { ... } } end
  end
  local function strict(cond, msg)
    if not cond then
      J.strict_errors[#J.strict_errors + 1] = msg
      error("juju(strict): " .. msg, 3)
    end
  end
  local function maybe_throw(name)
    if J.throw[name] then error("juju." .. name .. " forced failure", 3) end
  end

  function api.create_tab(func)
    rec("create_tab", func); maybe_throw("create_tab")
    strict(func == nil or type(func) == "function", "create_tab(func?: function)")
    J.tabs = J.tabs + 1
    J.current_tab = J.tabs
    if func then func() end
  end

  function api.create_section(name, side, size, offset)
    rec("create_section", name, side, size, offset); maybe_throw("create_section")
    strict(J.current_tab, "create_section before create_tab")
    strict(type(name) == "string", "create_section name must be string")
    strict(side == 1 or side == 2, "create_section side must be 1 or 2")
    strict(type(size) == "number" and size >= 0 and size <= 1, "create_section size 0-1")
    strict(type(offset) == "number" and offset >= 0 and offset <= 0.9, "create_section offset 0-0.9")
    local section = { name = name }
    function section:create_element(info, elements)
      rec("create_element", info, elements); maybe_throw("create_element")
      strict(type(info) == "table", "create_element info must be table")
      strict(type(info.name) == "string", "element name must be string")
      strict(info.type == "toggle" or info.type == "slider", "undocumented element type: " .. tostring(info.type))
      if info.type == "slider" then
        strict(type(info.min) == "number" and type(info.max) == "number", "slider needs numeric min/max")
        strict(info.min < info.max, "slider min < max")
      end
      strict(type(elements) == "table" and type(elements.callback) == "function", "elements.callback must be function")
      local el = { info = info, section = name, value = (info.type == "toggle") and false or info.min,
        callback = elements.callback, sets = 0 }
      if not J.no_set_value then      -- docs show set_value only on find_element results
        function el:set_value(v)
          self.value = v
          self.sets = self.sets + 1
          self.callback(v)       -- worst case: programmatic set also fires the callback
        end
      end
      function el:get_value() return self.value end
      J.elements[#J.elements + 1] = el
      if J.fire_on_create then elements.callback(el.value) end    -- host that pushes defaults at creation
      return el
    end
    J.sections[#J.sections + 1] = section
    return section
  end

  -- documented top-level form: juju.create_element(section: string, info, elements)
  function api.create_element(section_name, info, elements)
    rec("create_element_top", section_name, info, elements)
    strict(type(section_name) == "string", "create_element(section: string, ...)")
    for i = 1, #J.sections do
      if J.sections[i].name == section_name then return J.sections[i]:create_element(info, elements) end
    end
    error("juju(strict): no section named " .. section_name)
  end

  function api.find_element(parent, name)
    rec("find_element", parent, name)
    strict(type(parent) == "string" and type(name) == "string", "find_element(parent, name)")
    local p, n = string.lower(parent), string.lower(name)
    strict(not string.find(p, "config") and not string.find(p, "unload") and not string.find(n, "config")
      and not string.find(n, "unload"), "find_element name contains config/unload")
    for i = 1, #J.elements do
      local e = J.elements[i]
      if string.lower(e.section) == p and string.lower(e.info.name) == n then return e end
    end
    return nil
  end

  function api.set_tab_text(text)
    rec("set_tab_text", text); maybe_throw("set_tab_text")
    strict(type(text) == "string", "set_tab_text(text: string)")
    J.tab_text = string.sub(text, 1, 12)
    J.tab_text_calls = (J.tab_text_calls or 0) + 1
  end

  function api.create_connection(signal, callback)
    rec("create_connection", signal, callback); maybe_throw("create_connection")
    strict(type(signal) == "table" and type(signal.Connect) == "function", "create_connection needs a signal")
    strict(type(callback) == "function", "create_connection callback must be function")
    local conn = signal:Connect(callback)
    J.managed[#J.managed + 1] = conn
    return conn
  end

  function api.on_unload(func)
    rec("on_unload", func)
    strict(type(func) == "function", "on_unload(func)")
    J.unload_cbs[#J.unload_cbs + 1] = func
  end

  function api.get_signal(name)
    rec("get_signal", name)
    return J.signals[name]
  end
  function api.get_signals()
    rec("get_signals")
    local r = {}
    for k in pairs(J.signals) do r[#r + 1] = k end
    table.sort(r)
    return r
  end

  function api.get_flag(name)
    rec("get_flag", name); maybe_throw("get_flag")
    strict(type(name) == "string", "get_flag(name: string)")
    if RESERVED[name] then return nil end
    return J.flags[name]
  end
  function api.set_flag(name, value)
    rec("set_flag", name, value); maybe_throw("set_flag")
    strict(type(name) == "string", "set_flag(name: string)")
    strict(not RESERVED[name], "set_flag with reserved name " .. tostring(name))
    J.flags[name] = value
  end
  function api.get_flags()
    rec("get_flags"); maybe_throw("get_flags")
    local r = {}
    for k in pairs(J.flags) do if not RESERVED[k] then r[#r + 1] = k end end
    table.sort(r)
    return r
  end

  function api.get_ping()
    rec("get_ping"); maybe_throw("get_ping")
    local p = J.ping
    if type(p) == "function" then return p() end
    return p
  end
  function api.get_server_cframe()
    rec("get_server_cframe"); maybe_throw("get_server_cframe")
    if J.server_pos == nil then return nil end
    return { Position = J.server_pos }
  end
  function api.get_client_cframe()
    rec("get_client_cframe"); maybe_throw("get_client_cframe")
    if J.client_pos == nil then return nil end
    return { Position = J.client_pos }
  end
  function api.get_ragebot_target()
    rec("get_ragebot_target"); maybe_throw("get_ragebot_target")
    return J.ragebot_target
  end
  function api.get_ragebot_targets() rec("get_ragebot_targets"); return {} end

  -- mutating / out-of-scope APIs: exist in Juju, must NEVER be called by this addon
  for _, n in ipairs({ "set_ragebot_target", "add_ragebot_target", "remove_ragebot_target",
    "set_player_status", "set_server_cframe", "purchase_item", "load_config", "get_player_status",
    "is_in_void", "is_auto_stomping", "is_purchasing" }) do
    api[n] = function(...)
      rec(n, ...)
      J.violations[#J.violations + 1] = n
    end
  end

  -- simulate Juju unloading the addon
  function J.unload()
    for i = 1, #J.managed do pcall(function() J.managed[i]:Disconnect() end) end
    for i = 1, #J.unload_cbs do pcall(J.unload_cbs[i]) end
  end

  -- simulate the user touching a control
  function J.user_set(section, name, value)
    for i = 1, #J.elements do
      local e = J.elements[i]
      if e.section == section and e.info.name == name then
        e.value = value
        e.callback(value)
        return true
      end
    end
    error("no such element " .. section .. "/" .. name)
  end

  function J.element(section, name)
    for i = 1, #J.elements do
      local e = J.elements[i]
      if e.section == section and e.info.name == name then return e end
    end
  end

  function J.count_calls(name)
    local n = 0
    for i = 1, #J.calls do if J.calls[i].name == name then n = n + 1 end end
    return n
  end

  return J
end

-- ---------------------------------------------------------------------------------------
-- Drawing mock
-- ---------------------------------------------------------------------------------------
function M.new_drawing()
  local D = { live = 0, created = 0, objects = {}, fail = false }
  D.new = function(kind)
    if D.fail then error("Drawing.new failed") end
    assert(kind == "Text", "only Text drawings are used by the addon")
    D.live = D.live + 1
    D.created = D.created + 1
    -- the visible object stays EMPTY so __newindex fires for every assignment, existing key or not
    local store = { Text = "", Visible = false, text_sets = 0, removed = false }
    local o = setmetatable({}, {
      __index = function(_, k)
        if k == "Remove" then
          return function()
            if not store.removed then
              store.removed = true
              D.live = D.live - 1
            end
          end
        end
        return store[k]
      end,
      __newindex = function(_, k, v)
        if D.fail_on == k then error("Drawing property '" .. k .. "' rejected") end
        if k == "Text" then store.text_sets = store.text_sets + 1 end
        store[k] = v
      end,
    })
    D.objects[#D.objects + 1] = o
    return o
  end
  return D
end

-- ---------------------------------------------------------------------------------------
-- Environment bundle
-- ---------------------------------------------------------------------------------------
function M.env(sim, game, J, extras)
  extras = extras or {}
  local out = {}
  local genv = {}
  local env = {
    juju = (not extras.no_juju) and J.api or nil, game = game.game, task = sim.task,
    Drawing = extras.drawing, Vector2 = { new = function(x, y) return { X = x, Y = y } end },
    Color3 = { new = function(r, g, b) return { R = r, G = g, B = b } end },
    print = function(...)
      local parts = {}
      for i = 1, select("#", ...) do parts[i] = tostring((select(i, ...))) end
      out[#out + 1] = table.concat(parts, " ")
    end,
    getgenv = function() return genv end, os_clock = sim.clock, shared = genv,
  }
  env.warn = env.print
  env.output = out
  env.genv = genv
  for k, v in pairs(extras.override or {}) do env[k] = v end
  return env
end

return M
