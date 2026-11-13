-- The menu as real Juju addons build it:
--   juju.create_element({ name = .., section = .. }, { toggle = { flag = .., default = .. } })
-- No create_tab / create_section (they return nil in that build). State lives in the bound flag;
-- elements expose on_toggle_change / set_toggle.
local T = require("tf")
local H = require("harness")
local Signal = H.Mock.Signal

T.suite("24 Addon-style menu")

local function addon(opts)
  opts = opts or {}
  local pre = opts.pre
  return H.standard({
    config = opts.config,
    pre = function(x)
      x.J.element_api = "addon"
      if opts.no_change_signal then x.J.no_change_signal = true end
      if pre then pre(x) end
    end,
  })
end

T.test("builds every control without create_tab/create_section", function()
  local c = addon()
  T.ok(c.inst, tostring(c.err))
  T.eq(c.inst.ui.menu_style, "addon")
  T.ok(c.inst.ui.menu_ok)
  T.eq(#c.J.elements, 11)
  T.eq(c.J.tabs, 0, "an addon-style host needs no tab")
  T.eq(#c.J.sections, 0)
  T.contains(c.inst.report(), "menu: addon (11 controls)")
end)

T.test("sections are plain strings on the info table", function()
  local c = addon()
  local byname = {}
  for _, e in ipairs(c.J.elements) do byname[e.info.name] = e end
  T.eq(byname["Enabled"].section, "Hit Checker")
  T.eq(byname["Auto Mode DBS"].section, "Auto Mode")
  T.eq(byname["Max window ms"].kind, "slider")
  T.eq(byname["Max window ms"].conf.min, 250)
  T.eq(byname["Max window ms"].conf.max, 3000)
end)

T.test("controls start from the current configuration", function()
  local c = addon({ config = { hud = false, auto_mode = true, scope = "all", window_max = 1.25 } })
  local byname = {}
  for _, e in ipairs(c.J.elements) do byname[e.info.name] = e end
  T.eq(byname["Show HUD"].value, false)
  T.eq(byname["Auto Mode DBS"].value, true)
  T.eq(byname["Scope 1auto 2tgt 3all"].value, 3)
  T.eq(byname["Max window ms"].value, 1250)
  -- and creating them must not have rewritten the config
  T.eq(c.inst.cfg.scope, "all")
  T.near(c.inst.cfg.window_max, 1.25, 1e-9)
  T.eq(c.inst.auto.state, "ACTIVE")
end)

T.test("toggling Enabled through the menu stops and starts tracking", function()
  local c = addon()
  H.run(c, 2)
  c.J.user_set("Hit Checker", "Enabled", false)
  T.eq(c.inst.cfg.enabled, false)
  H.shoot(c); H.settle(c)
  T.eq(H.stats(c).attempted, 0)
  c.J.user_set("Hit Checker", "Enabled", true)
  T.eq(c.inst.cfg.enabled, true)
  H.shoot(c); H.settle(c)
  T.eq(H.stats(c).attempted, 1)
end)

T.test("sliders feed the configuration with unit conversion", function()
  local c = addon()
  c.J.user_set("Hit Checker", "Max window ms", 1800)
  H.run(c, 1)
  T.near(c.inst.cfg.window_max, 1.8, 1e-9)
  c.J.user_set("Auto Mode", "Scope 1auto 2tgt 3all", 2)
  H.run(c, 1)
  T.eq(c.inst.cfg.scope, "target")
end)

T.test("momentary buttons act once and reset their flag", function()
  local c = addon()
  H.shoot(c); H.settle(c)
  T.eq(H.stats(c).attempted, 1)
  c.J.user_set("Hit Checker", "Reset stats", true)
  T.eq(H.stats(c).attempted, 0)
  T.eq(c.J.flags.jhc_ui_reset, false, "the button flag must be cleared again")
  H.run(c, 1)
  T.eq(H.stats(c).attempted, 0, "and it must not fire repeatedly from the flag poll")
end)

T.test("Print report works from the menu", function()
  local c = addon()
  c.J.user_set("Hit Checker", "Print report", true)
  T.contains(table.concat(c.env.output, "\n"), "JHC report")
  T.eq(c.J.flags.jhc_ui_report, false)
end)

T.test("a host with no change signals is driven by the flag poll alone", function()
  local c = addon({ no_change_signal = true })
  H.run(c, 2)
  T.eq(c.inst.cfg.enabled, true)
  c.J.flags.jhc_cfg_enabled = false          -- the host wrote the flag, no signal fired
  H.run(c, 2)
  T.eq(c.inst.cfg.enabled, false, "the poll must pick the change up")
  c.J.flags.jhc_ui_window_max = 900
  H.run(c, 2)
  T.near(c.inst.cfg.window_max, 0.9, 1e-9)
end)

T.test("the flag poll never fights the config when nothing changed", function()
  local c = addon()
  H.run(c, 2)
  local before = c.inst.cfg.window_max
  local problems = #c.inst.cfgobj.problems
  H.run(c, 20)
  T.near(c.inst.cfg.window_max, before, 1e-9)
  T.eq(#c.inst.cfgobj.problems, problems, "idle polling must not log config problems")
end)

T.test("Auto Mode and HUD controls work through the addon API", function()
  local c = addon()
  T.eq(c.inst.auto.state, "OFF")
  c.J.user_set("Auto Mode", "Auto Mode DBS", true)
  T.eq(c.inst.auto.state, "ACTIVE")
  H.run(c, 1)
  T.eq(c.J.flags.jhc_auto_state, "ACTIVE")
  c.J.user_set("Hit Checker", "Show HUD", false)
  for _, o in ipairs(c.drawing.objects) do T.eq(o.Visible, false) end
end)

T.test("a host that announces defaults while creating elements cannot clobber the config", function()
  local c = addon({ pre = function(x) x.J.fire_on_create = true end,
    config = { enabled = true, hud = false, scope = "all", window_max = 1.3, auto_mode = true } })
  T.ok(c.inst, tostring(c.err))
  T.eq(c.inst.cfg.enabled, true)
  T.eq(c.inst.cfg.hud, false)
  T.eq(c.inst.cfg.scope, "all")
  T.near(c.inst.cfg.window_max, 1.3, 1e-9)
  T.eq(c.inst.cfg.auto_mode, true)
  T.eq(c.inst.auto.state, "ACTIVE")
  H.shoot(c); H.settle(c)
  T.eq(H.stats(c).attempted, 1, "and tracking still runs")
end)

T.test("menu signal connections are released on unload", function()
  local base = Signal.live_total
  local c = addon()
  H.run(c, 1)
  c.J.unload()
  T.eq(Signal.live_total, base, "menu listeners left connected")
  T.no_error(function() c.J.user_set("Hit Checker", "Enabled", false) end)
  T.eq(c.inst.cfg.enabled, true, "a click after unload must do nothing")
end)

T.test("if some controls fail the menu still reports what it built", function()
  local c = addon({ pre = function(x)
    local real = x.J.api.create_element
    local n = 0
    x.J.api.create_element = function(a, b)
      n = n + 1
      if n > 4 then error("juju: element limit reached") end
      return real(a, b)
    end
  end })
  T.ok(c.inst)
  T.eq(c.inst.ui.menu_style, "addon")
  T.ok(c.inst.ui.menu_ok)
  T.eq(#c.J.elements, 4)
  H.shoot(c); H.settle(c)
  T.eq(H.stats(c).attempted, 1, "tracking is unaffected by missing controls")
end)

return true
