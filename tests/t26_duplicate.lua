-- Repeat confirmations for a shot that is already credited.
--
-- LIVE: 16 of 69 confirmations were counted "unmatched", which read as 16 confirmed hits being
-- dropped. A second confirmation for the same shot arriving later than burst_gap finds its shot
-- already credited and falls through every path, so it landed in that bucket. Those are duplicates,
-- not losses, and the two are now counted apart so the distinction is visible in the report.
local T = require("tf")
local H = require("harness")

T.suite("26 Repeat confirmations")

local function fire_confirm(c, enemy, dmg)
  c.J.signals.on_local_bullet_confirmed:Fire(enemy, { Name = "Head" }, tostring(dmg or -15))
end

T.test("a later confirmation for an already-credited shot counts as a duplicate, not a loss", function()
  local c = H.standard({ ping = 35 })
  H.run(c, 2)
  H.shoot(c)
  c.sim.task.delay(0.10, function() fire_confirm(c, c.enemies[1]) end)
  c.sim.task.delay(0.25, function() fire_confirm(c, c.enemies[1]) end)   -- well past burst_gap
  H.settle(c)
  local s = H.stats(c)
  T.eq(s.attempted, 1)
  T.eq(s.hits, 1, "still exactly one hit")
  T.eq(c.inst.engine.counters.confirm_duplicate, 1)
  T.eq(c.inst.engine.counters.confirm_unmatched, 0, "a duplicate must not read as a dropped hit")
  T.contains(c.inst.report(), "dup=1")
  H.check_invariant(c, T)
end)

T.test("pellets inside burst_gap are still counted as pellets, not duplicates", function()
  local c = H.standard({ ping = 35 })
  H.run(c, 2)
  H.shoot(c)
  c.sim.task.delay(0.10, function() fire_confirm(c, c.enemies[1]) end)
  c.sim.task.delay(0.115, function() fire_confirm(c, c.enemies[1]) end)
  H.settle(c)
  T.eq(c.inst.engine.counters.confirm_pellets, 1)
  T.eq(c.inst.engine.counters.confirm_duplicate, 0)
  T.eq(H.stats(c).hits, 1)
end)

T.test("a second genuine shot still gets its own credit, not a duplicate", function()
  local c = H.standard({ ping = 35 })
  H.run(c, 2)
  H.shoot(c)
  c.sim.task.delay(0.10, function() fire_confirm(c, c.enemies[1]) end)
  H.run(c, 0.5)
  H.shoot(c)                                   -- a real second shot at the same target
  c.sim.task.delay(0.10, function() fire_confirm(c, c.enemies[1]) end)
  H.settle(c)
  local s = H.stats(c)
  T.eq(s.attempted, 2)
  T.eq(s.hits, 2, "both shots must be credited")
  T.eq(c.inst.engine.counters.confirm_duplicate, 0)
  H.check_invariant(c, T)
end)

T.test("a true orphan is still reported as unmatched and logged", function()
  local c = H.standard({ ping = 35 })
  H.run(c, 2)
  fire_confirm(c, c.enemies[1])                -- never fired a shot at all
  H.run(c, 1)
  T.eq(H.stats(c).hits, 0)
  T.eq(c.inst.engine.counters.confirm_unmatched, 1)
  T.eq(c.inst.engine.counters.confirm_duplicate, 0)
  local found = false
  for _, e in ipairs(c.inst.engine:recent_events(5)) do
    if e.kind == "confirm_orphan" then found = true end
  end
  T.ok(found, "an orphan must be visible in the event log")
end)

T.test("a duplicate beyond confirm_horizon is an orphan again", function()
  local c = H.standard({ ping = 35, config = { confirm_horizon = 0.4 } })
  H.run(c, 2)
  H.shoot(c)
  c.sim.task.delay(0.10, function() fire_confirm(c, c.enemies[1]) end)
  H.run(c, 1.2)
  fire_confirm(c, c.enemies[1])                -- far too late to belong to that shot
  H.run(c, 0.5)
  T.eq(c.inst.engine.counters.confirm_duplicate, 0)
  T.eq(c.inst.engine.counters.confirm_unmatched, 1)
end)

T.test("duplicates never inflate the hit count under rapid repeat confirmations", function()
  local c = H.standard({ ping = 35 })
  H.run(c, 2)
  H.shoot(c)
  for i = 1, 10 do
    c.sim.task.delay(0.10 + i * 0.05, function() fire_confirm(c, c.enemies[1]) end)
  end
  H.settle(c)
  local s = H.stats(c)
  T.eq(s.attempted, 1)
  T.eq(s.hits, 1)
  T.ok(c.inst.engine.counters.confirm_duplicate >= 8)
  H.check_invariant(c, T)
end)

return true
