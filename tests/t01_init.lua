local T = require("tf")
local H = require("harness")
local Signal = H.Mock.Signal

T.suite("01 Addon initialization")

T.test("boots under the strict documented-API Juju mock and builds the menu", function()
  local c = H.standard()
  T.ok(c.inst, "inst: " .. tostring(c.err))
  T.eq(c.J.tabs, 1, "one tab")
  T.eq(#c.J.sections, 2, "two sections")
  T.eq(#c.J.elements, 11, "eleven controls")
  T.eq(#c.J.strict_errors, 0, "strict API violations: " .. table.concat(c.J.strict_errors, "; "))
  T.ok(c.inst.ui.menu_ok)
end)

T.test("registers exactly one unload hook", function()
  local c = H.standard()
  T.eq(#c.J.unload_cbs, 1)
end)

T.test("publishes jhc_loaded / jhc_version after the first throttled refresh", function()
  local c = H.standard()
  H.run(c, 0.6)
  T.eq(c.J.flags.jhc_loaded, true)
  T.eq(c.J.flags.jhc_version, "1.0.0")
  T.eq(c.J.flags.jhc_shots, 0)
end)

T.test("refuses to run without the juju global", function()
  local c = H.boot({ no_juju = true })
  T.is_nil(c.inst)
  T.contains(c.err, "juju")
  T.contains(c.env.output[1], "init failed")
end)

T.test("refuses to run without juju.on_unload (no cleanup hook)", function()
  local c = H.boot({ pre = function(x) x.J.api.on_unload = nil end })
  T.is_nil(c.inst)
  T.contains(c.err, "on_unload")
end)

T.test("refuses to run without task.delay / task.spawn", function()
  local c = H.boot({ override = { task = {} } })
  T.is_nil(c.inst)
  T.contains(c.err, "task")
end)

T.test("refuses to run without a monotonic clock", function()
  local c = H.boot({ override = { os_clock = false } })
  T.is_nil(c.inst)
  T.contains(c.err, "clock")
end)

T.test("starts degraded (not crashed) when LocalPlayer is missing", function()
  local c = H.boot({ pre = function(x) x.g.Players.LocalPlayer = nil end })
  T.ok(c.inst, tostring(c.err))
  T.is_nil(c.inst.world.lp)
  T.eq(#c.sim.errors, 0)
end)

T.test("menu API failure is non-fatal (tracking still starts)", function()
  local c = H.boot({ pre = function(x) x.J.throw.create_tab = true end })
  T.ok(c.inst, tostring(c.err))
  T.falsy(c.inst.ui.menu_ok)
  T.eq(#c.J.elements, 0)
end)

T.test("missing optional Juju functions degrade gracefully", function()
  local c = H.boot({ pre = function(x)
    x.J.api.get_ping = nil; x.J.api.get_server_cframe = nil; x.J.api.get_client_cframe = nil
    x.J.api.get_flags = nil; x.J.api.get_ragebot_target = nil; x.J.api.set_tab_text = nil
  end })
  T.ok(c.inst, tostring(c.err))
  T.falsy(c.inst.host.caps.get_ping)
  H.run(c, 3)
  T.eq(c.inst.diag.n_samples, 0)
  T.eq(#c.sim.errors, 0)
end)

T.test("mid-init failure cleans up everything it created", function()
  local base = Signal.live_total
  local c = H.standard({ pre = function(x) x.sim.task.spawn = function() error("spawn failed") end end })
  T.is_nil(c.inst)
  T.contains(c.err, "spawn failed")
  T.eq(Signal.live_total, base, "leaked connections after failed init")
  T.eq(c.drawing.live, 0, "leaked Drawing objects")
  T.is_nil(c.env.genv.__JHC_INSTANCE)
end)

T.test("invalid configuration is reported, defaults are used", function()
  local c = H.standard({ config = { scope = "bogus", window_min = -5, nonsense = 1, hud_size = "big" } })
  T.ok(c.inst)
  T.eq(c.inst.cfg.scope, "auto")
  T.ok(c.inst.cfg.window_min >= 0.05)
  T.ok(#c.inst.cfgobj.problems >= 3)
end)

T.test("loading twice replaces the old instance without leaking connections", function()
  local c = H.standard()
  H.run(c, 1)                          -- let the one-time create_connection probe finish and clean up
  local after_first = Signal.live_total
  local first = c.inst
  local second = require("main").start(nil, c.env)
  H.run(c, 1)
  T.ok(second)
  T.ok(first.dead, "old instance must be shut down")
  T.neq(first, second)
  T.eq(Signal.live_total, after_first, "second load must not stack connections")
  T.eq(c.env.genv.__JHC_INSTANCE, second)
  -- the old instance's timers/handlers are inert
  H.shoot(c)
  H.run(c, 2)
  T.eq(first.engine:stats("all").attempted, 0)
  T.eq(second.engine:stats("all").attempted, 1)
end)

T.test("unload via Juju tears everything down", function()
  local base = Signal.live_total
  local c = H.standard()
  H.run(c, 1)
  c.J.unload()
  T.ok(c.inst.dead)
  T.eq(Signal.live_total, base, "connections left after unload")
  T.eq(c.drawing.live, 0, "Drawing objects left after unload")
  T.is_nil(c.env.genv.__JHC_INSTANCE)
  H.run(c, 10)   -- stray timers / sampler must be inert
  T.eq(#c.sim.errors, 0)
end)

return true
