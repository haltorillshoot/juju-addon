-- Regression tests for behaviour OBSERVED LIVE (Potassium client, script run outside Juju's addon
-- loader): juju.create_connection returned nil and connected nothing, juju.create_section returned
-- nil. The mocks now reproduce those behaviours.
local T = require("tf")
local H = require("harness")
local Signal = H.Mock.Signal

T.suite("20 Live findings")

T.test("create_connection that does nothing and returns nil: direct connections, exactly one listener each", function()
  local c = H.standard({ pre = function(x) x.J.cc_mode = "noop_nil" end })
  T.ok(c.inst, tostring(c.err))
  T.eq(c.tool.Activated.live, 1)
  T.ok(c.inst.host.connect_fallbacks > 5)
  T.eq(c.inst.errors, 0)
  H.shoot_hit(c, c.enemies[1], 0.07, 10); H.settle(c)
  T.eq(H.stats(c).hits, 1)
  H.run(c, 1)
  T.eq(c.inst.host.connect_behaviour, "noop_returns_nil")
  T.contains(table.concat(c.env.output, "\n"), "did nothing")
end)

T.test("direct connections are released on unload (nothing leaks when Juju does not track them)", function()
  local base = Signal.live_total
  local c = H.standard({ pre = function(x) x.J.cc_mode = "noop_nil" end })
  H.run(c, 1)
  c.J.unload()
  T.eq(Signal.live_total, base)
  T.eq(c.tool.Activated.live, 0)
end)

T.test("create_connection that connects but returns nil is detected and warned about", function()
  local c = H.standard({ pre = function(x) x.J.cc_mode = "connect_nil" end })
  H.run(c, 1)
  T.eq(c.inst.host.connect_behaviour, "connects_returns_nil")
  T.ok(c.inst.host.dup_risk)
  T.contains(table.concat(c.env.output, "\n"), "registered twice")
  T.contains(c.inst.report(), "duplicate-listener risk")
end)

T.test("documented behaviour is recognised and the probe cleans up after itself", function()
  local base = Signal.live_total
  local c = H.standard()
  local during_probe = Signal.live_total
  H.run(c, 1)
  T.eq(c.inst.host.connect_behaviour, "returns_connection")
  T.falsy(c.inst.host.dup_risk)
  T.eq(c.inst.host.connect_fallbacks, 0)
  T.eq(Signal.live_total, during_probe - 1, "exactly the probe's throwaway connection must disappear")
  T.contains(c.inst.report(), "create_connection behaviour=returns_connection")
  c.J.unload()
  T.eq(Signal.live_total, base, "nothing left after unload")
end)

T.test("create_section returning nil: ONE clear message, menu reported as unavailable, tracking still works", function()
  local c = H.standard({ pre = function(x) x.J.section_returns_nil = true end })
  T.ok(c.inst, tostring(c.err))
  T.falsy(c.inst.ui.menu_ok)
  T.eq(#c.J.elements, 0)
  local out = table.concat(c.env.output, "\n")
  T.contains(out, "create_section returned nil")
  T.contains(out, "menu=false")
  local n = 0
  for _ in string.gmatch(out, "create_element") do n = n + 1 end
  T.eq(n, 0, "no per-control error spam")
  H.shoot_hit(c, c.enemies[1], 0.07, 10); H.settle(c)
  T.eq(H.stats(c).hits, 1)
  T.ok(c.drawing.live > 0, "HUD still works without the menu")
end)

T.test("the console report works without a menu (the only controls left)", function()
  local c = H.standard({ pre = function(x) x.J.section_returns_nil = true end })
  H.shoot(c); H.settle(c)
  T.contains(c.inst.report(), "JHC report")
end)

return true
