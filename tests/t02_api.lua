local T = require("tf")
local H = require("harness")
local Signal = H.Mock.Signal

T.suite("02 Juju API compatibility")

local ALLOWED = { create_tab = true, create_section = true, create_element = true, set_tab_text = true,
  create_connection = true, on_unload = true, get_flag = true, set_flag = true, get_flags = true,
  get_ping = true, get_server_cframe = true, get_client_cframe = true, get_ragebot_target = true,
  get_signal = true }

-- exercise every feature once
local function full_session()
  local base = Signal.live_total
  local c = H.standard({ ammo = 2, ping = 80 })
  c.J.ragebot_target = c.enemies[1]
  c.J.server_pos = H.Mock.Vector3(0, 0, 0)
  c.J.client_pos = H.Mock.Vector3(3, 0, 4)
  c.J.flags.ragebot = true
  c.J.flags.auto_mode = true
  H.run(c, 1.2)
  for i = 1, 6 do
    c.tool.ammo:SetValue(c.tool.ammo.Value - 1)
    H.shoot_hit(c, c.enemies[1], 0.09, 25)
    H.run(c, 2)
    c.tool.ammo:SetValue(2)
  end
  H.shoot(c); H.run(c, 2)                               -- a miss
  c.J.user_set("Auto Mode", "Auto Mode DBS", true)
  c.J.user_set("Auto Mode", "Follow Juju auto", true)
  c.J.user_set("Auto Mode", "Scope 1auto 2tgt 3all", 2)
  c.J.user_set("Hit Checker", "Show HUD", false)
  c.J.user_set("Hit Checker", "Show HUD", true)
  c.J.user_set("Hit Checker", "Debug log", true)
  c.J.user_set("Hit Checker", "Debug log", false)
  c.J.user_set("Hit Checker", "Live tab summary", true)
  c.J.user_set("Hit Checker", "Max window ms", 1200)
  c.J.user_set("Hit Checker", "Min window ms", 300)
  c.J.user_set("Hit Checker", "Print report", true)
  c.J.user_set("Hit Checker", "Reset stats", true)
  H.run(c, 3)
  c.J.user_set("Hit Checker", "Enabled", false)
  c.J.user_set("Hit Checker", "Enabled", true)
  H.run(c, 3)
  c.J.unload()
  return c, base
end

T.test("full feature session raises no strict-API violation", function()
  local c = full_session()
  T.eq(#c.J.strict_errors, 0, table.concat(c.J.strict_errors, "; "))
  T.eq(#c.sim.errors, 0, table.concat(c.sim.errors, "; "))
end)

T.test("only documented, read-only Juju functions are ever called", function()
  local c = full_session()
  for i = 1, #c.J.calls do
    T.ok(ALLOWED[c.J.calls[i].name], "unexpected juju call: " .. c.J.calls[i].name)
  end
  T.eq(#c.J.violations, 0, "mutating/out-of-scope API called: " .. table.concat(c.J.violations, ","))
end)

T.test("UI uses only documented element types, legal names, 12-char tab text", function()
  local c = full_session()
  for _, e in ipairs(c.J.elements) do
    T.ok(e.info.type == "toggle" or e.info.type == "slider", "element type " .. e.info.type)
    local n = string.lower(e.info.name)
    T.falsy(string.find(n, "config") or string.find(n, "unload"), "reserved word in name " .. e.info.name)
  end
  for i = 1, #c.J.calls do
    local call = c.J.calls[i]
    if call.name == "set_tab_text" then
      T.ok(#call.args[1] <= 12, "tab text too long: " .. tostring(call.args[1]))
    end
  end
end)

T.test("only jhc_* flags are written and reserved names never are", function()
  local c = full_session()
  local n = 0
  for i = 1, #c.J.calls do
    local call = c.J.calls[i]
    if call.name == "set_flag" then
      n = n + 1
      T.eq(string.sub(call.args[1], 1, 4), "jhc_", "flag outside namespace: " .. call.args[1])
      T.falsy(call.args[1] == "author" or call.args[1] == "date" or call.args[1] == "loaded_addons")
    end
  end
  T.ok(n > 0, "expected some flag writes")
  T.eq(c.J.flags.ragebot, true, "host flag must be untouched")
end)

T.test("host.set_flag refuses names outside the jhc_ namespace", function()
  local c = H.standard()
  local ok, why = c.inst.host.set_flag("ragebot", false)
  T.falsy(ok)
  T.contains(why, "refused")
  T.eq(c.inst.host.refused_flag_writes, 1)
  T.is_nil(c.J.flags.ragebot)
  T.falsy(c.inst.host.set_flag("author", "x"))
end)

T.test("every connection goes through juju.create_connection and is released on unload", function()
  local c, base = full_session()
  T.ok(c.J.count_calls("create_connection") > 5)
  T.eq(Signal.live_total, base, "leaked connections: " .. tostring(Signal.live_total - base))
end)

T.test("on a documented-style host it ends up using section:create_element(info, {callback=})", function()
  local c = H.standard()
  T.eq(c.inst.ui.menu_style, "documented")
  local method_calls = 0
  for _, call in ipairs(c.J.calls) do
    -- the first call is the addon-style probe (info table + element-type table); the host rejects
    -- it and the addon falls back. Every element that is actually created goes through the
    -- documented method form, whose recorded args are (info, { callback = fn }).
    if call.name == "create_element" and type(call.args[2]) == "table" and call.args[2].callback then
      method_calls = method_calls + 1
      T.eq(type(call.args[1]), "table")
      T.eq(type(call.args[2].callback), "function")
    end
  end
  T.eq(method_calls, 11, "all eleven controls created through the documented form")
end)

T.test("on an addon-style host it uses create_element(info, {type={flag=..}}) and no tab/section", function()
  local c = H.standard({ pre = function(x) x.J.element_api = "addon" end })
  T.ok(c.inst, tostring(c.err))
  T.eq(c.inst.ui.menu_style, "addon")
  T.eq(#c.J.elements, 11)
  for _, e in ipairs(c.J.elements) do
    T.ok(e.kind == "toggle" or e.kind == "slider", "element kind " .. tostring(e.kind))
    T.eq(type(e.conf.flag), "string")
    T.eq(string.sub(e.conf.flag, 1, 4), "jhc_", "controls must bind flags in our own namespace")
  end
  T.eq(#c.J.strict_errors, 0, table.concat(c.J.strict_errors, "; "))
  T.eq(#c.J.violations, 0)
end)

T.test("capability probe reflects what the host provides", function()
  local c = H.standard()
  local caps = c.inst.host.caps
  T.ok(caps.create_tab and caps.create_section and caps.create_element and caps.on_unload)
  T.ok(caps.get_ping and caps.get_server_cframe and caps.get_client_cframe)
  T.ok(caps.drawing)
  T.contains(c.inst.report(), "capabilities")
end)

return true
