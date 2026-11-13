local T = require("tf")
local H = require("harness")

T.suite("04 Miss detection")

T.test("no damage in the window on a healthy connection is a miss", function()
  local c = H.standard()
  H.shoot(c)
  H.settle(c)
  local s = H.stats(c)
  T.eq(s.misses, 1); T.eq(s.hits, 0); T.eq(s.unconfirmed, 0); T.eq(s.hit_pct, 0)
  T.eq(c.inst.engine.last_shot.outcome, "miss")
  H.check_invariant(c, T); H.clean_sim(c, T)
end)

T.test("a shot stays pending until its window closes", function()
  local c = H.standard()
  H.shoot(c)
  local w = c.inst.engine.last_shot.window
  T.near(w, c.inst.cfg.window_min, 1e-9, "window for a 60ms ping is the configured minimum")
  H.run(c, w - 0.01)
  T.eq(H.stats(c).pending, 1)
  T.eq(H.stats(c).misses, 0)
  H.run(c, 0.02)
  T.eq(H.stats(c).pending, 0)
  T.eq(H.stats(c).misses, 1)
end)

T.test("nothing observable -> unconfirmed, never a miss", function()
  local c = H.standard({ enemies = 0 })
  H.shoot(c)
  H.settle(c)
  T.eq(H.stats(c).misses, 0)
  T.eq(H.stats(c).unconfirmed, 1)
  T.eq(c.inst.engine.last_shot.reason, "no_observable_target")
end)

T.test("ping spike inside the window -> unconfirmed, not a miss", function()
  local c = H.standard()
  H.run(c, 8)                          -- baseline samples at 60ms
  c.J.ping = 900
  H.shoot(c)
  c.J.ping = 60
  H.settle(c)
  T.eq(H.stats(c).misses, 0)
  T.eq(c.inst.engine.last_shot.outcome, "unconfirmed")
  T.eq(c.inst.engine.last_shot.reason, "degraded:ping_spike")
  H.check_invariant(c, T)
end)

T.test("client stall (timers firing late) -> unconfirmed, not a miss", function()
  local c = H.standard()
  H.run(c, 3)
  H.shoot(c)
  c.sim:freeze(5)                      -- the whole client hangs for 5s
  T.eq(H.stats(c).misses, 0)
  T.eq(c.inst.engine.last_shot.outcome, "unconfirmed")
  T.contains(c.inst.engine.last_shot.reason, "degraded")
end)

T.test("validated ammo source with no decrement -> not_fired (cooldown / empty), not a miss", function()
  local c = H.standard({ ammo = 2 })
  H.shoot(c)
  c.tool.ammo:SetValue(1)                 -- calibration: the counter is seen to drop on a shot
  H.settle(c)
  T.eq(H.stats(c).misses, 1)
  c.tool.ammo:SetValue(2)
  H.shoot(c)                              -- this click produces no decrement
  H.settle(c)
  local s = H.stats(c)
  T.eq(s.not_fired, 1); T.eq(s.misses, 1)
  H.check_invariant(c, T)
end)

T.test("an UNVALIDATED ammo source is never used to call a miss 'not_fired'", function()
  local c = H.standard({ ammo = 2 })       -- 'Ammo' exists but has never been seen to change
  H.shoot(c); H.settle(c)
  local s = H.stats(c)
  T.eq(s.misses, 1); T.eq(s.not_fired, 0)
  T.contains(c.inst.report(), "unvalidated")
end)

T.test("ammo decrement + no damage -> genuine miss with fire confirmation", function()
  local c = H.standard({ ammo = 2 })
  H.shoot(c)
  c.tool.ammo:SetValue(1)
  H.settle(c)
  local s = H.stats(c)
  T.eq(s.misses, 1); T.eq(s.fired, 1); T.eq(s.not_fired, 0)
end)

T.test("damage just after the window re-classifies the miss (never silently kept as a miss)", function()
  local c = H.standard()
  H.shoot(c)
  local w = c.inst.engine.last_shot.window
  local grace = c.inst.cfg.late_grace * w
  H.damage_after(c, c.enemies[1], w + grace * 0.5, 20)
  H.run(c, w + 0.01)
  T.eq(H.stats(c).misses, 1, "declared a miss at the deadline")
  H.run(c, grace)
  local s = H.stats(c)
  T.eq(s.misses, 0, "contradicted by late damage")
  T.eq(s.hits, 0, "and NOT promoted to a hit")
  T.eq(s.unconfirmed, 1)
  T.eq(c.inst.engine.counters.late_damage, 1)
  T.eq(c.inst.engine.reasons.late_damage, 1)
  H.check_invariant(c, T)
end)

T.test("damage long after the window does NOT spoil a correct miss", function()
  local c = H.standard()
  H.shoot(c)
  local w = c.inst.engine.last_shot.window
  H.damage_after(c, c.enemies[1], w + c.inst.cfg.late_grace * w + 0.5, 20)   -- someone else, much later
  H.settle(c)
  T.eq(H.stats(c).misses, 1)
  T.eq(H.stats(c).unconfirmed, 0)
  T.eq(c.inst.engine.counters.late_damage, 0)
end)

T.test("default: late damage never feeds back into the window (no feedback loop)", function()
  local c = H.standard()
  local before = c.inst.diag:window()
  for i = 1, 10 do
    H.shoot(c)
    H.damage_after(c, c.enemies[1], 0.27, 20)
    H.run(c, 1.5)
  end
  T.near(c.inst.diag:window(), before, 1e-9)
end)

T.test("learn_window=true (opt-in): slow replication widens the window", function()
  local c = H.standard({ config = { learn_window = true } })
  local before = c.inst.diag:window()
  for i = 1, 8 do
    H.shoot(c)
    H.damage_after(c, c.enemies[1], 0.27, 20)    -- slower than the 200ms window, inside the grace
    H.run(c, 1.5)
  end
  T.ok(c.inst.diag:window() > before, "window did not adapt")
  H.shoot_hit(c, c.enemies[1], 0.30, 20)
  H.settle(c)
  T.eq(c.inst.engine.last_shot.outcome, "hit", "adapted window now catches it")
end)

T.test("scope=target ignores damage on non-target players -> miss", function()
  local c = H.standard({ enemies = 2 })
  c.J.ragebot_target = c.enemies[1]
  H.shoot_hit(c, c.enemies[2], 0.07, 20)
  H.settle(c)
  T.eq(H.stats(c).hits, 0)
  T.eq(H.stats(c).misses, 1)
  T.eq(c.inst.engine.counters.unattributed_damage, 1)
end)

T.test("scope=target counts damage on the ragebot target", function()
  local c = H.standard({ enemies = 2 })
  c.J.ragebot_target = c.enemies[1]
  H.shoot_hit(c, c.enemies[1], 0.07, 20)
  H.settle(c)
  T.eq(H.stats(c).hits, 1)
end)

T.test("overlapping second shot that cannot be told apart -> unconfirmed (ambiguous_overlap)", function()
  local c = H.standard()
  H.shoot(c)
  H.run(c, 0.05)
  H.shoot(c)
  H.damage_after(c, c.enemies[1], 0.02, 20)    -- t=0.07 : inside both windows
  H.damage_after(c, c.enemies[1], 0.03, 20)    -- same burst
  H.settle(c)
  local s = H.stats(c)
  T.eq(s.hits, 1)
  T.eq(s.misses, 0)
  T.eq(s.unconfirmed, 1)
  T.eq(c.inst.engine.reasons.ambiguous_overlap, 1)
end)

T.test("target leaves mid-window -> unconfirmed(target_lost)", function()
  local c = H.standard({ enemies = 1 })
  H.shoot(c)
  H.run(c, 0.05)
  c.g:remove_player(c.enemies[1])
  H.settle(c)
  T.eq(H.stats(c).misses, 0)
  T.eq(c.inst.engine.last_shot.reason, "target_lost")
end)

return true
