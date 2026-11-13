-- Late Juju confirmations.
--
-- LIVE: ping 32ms put the window at its 200ms floor, but confirmations arrive 200-330ms after the
-- shot. Every shot expired first, so 8 confirmed hits were recorded as 9 misses - and because the
-- window only learns from confirmed hits, it could never grow out of the hole. A confirmation that
-- lands after its shot expired now corrects the verdict and teaches the window.
local T = require("tf")
local H = require("harness")

T.suite("25 Late confirmations")

local function confirm(c, enemy, delay, dmg)
  c.sim.task.delay(delay, function()
    c.J.signals.on_local_bullet_confirmed:Fire(enemy, { Name = "Head" }, tostring(dmg or -85))
  end)
end

T.test("a confirmation after the window closed turns the miss into a confirmed hit", function()
  local c = H.standard({ ping = 32 })
  H.run(c, 3)
  T.near(c.inst.diag:window(), c.inst.cfg.window_min, 1e-9, "the floor, as live")
  H.shoot(c)
  confirm(c, c.enemies[1], 0.31)              -- past the 200ms window and its 0.5x grace
  H.run(c, 0.25)
  T.eq(H.stats(c).misses, 1, "declared a miss when the window closed")
  H.settle(c)
  local s = H.stats(c)
  T.eq(s.misses, 0, "corrected once Juju confirmed it")
  T.eq(s.hits, 1)
  T.eq(s.confirmed_hits, 1)
  T.eq(c.inst.engine.counters.promoted, 1)
  T.near(c.inst.engine.last_shot.latency, 0.31, 1e-6)
  T.eq(c.inst.engine.last_shot.promoted_from, "miss")
  H.check_invariant(c, T)
end)

T.test("the live deadlock resolves itself: the window grows until confirmations land in time", function()
  local c = H.standard({ ping = 32 })
  H.run(c, 3)
  local start = c.inst.diag:window()
  for i = 1, 8 do
    H.shoot(c)
    confirm(c, c.enemies[1], 0.28)
    H.run(c, 2)
  end
  local grown = c.inst.diag:window()
  T.ok(grown > start, "window must learn from the promotions: " .. grown .. " vs " .. start)
  T.ok(grown >= 0.28, "and cover the observed confirmation latency")
  T.eq(H.stats(c).hits, 8)
  T.eq(H.stats(c).misses, 0)
  -- now a shot of the same kind resolves inside its own window, with no promotion needed
  local before = c.inst.engine.counters.promoted
  H.shoot(c)
  confirm(c, c.enemies[1], 0.28)
  H.settle(c)
  T.eq(c.inst.engine.counters.promoted, before, "no longer needs rescuing after the window adapted")
  T.eq(H.stats(c).hits, 9)
  H.check_invariant(c, T)
end)

T.test("promotion corrects an unconfirmed verdict and its reason counter", function()
  local c = H.standard({ enemies = 1, ping = 32 })
  H.run(c, 3)
  H.shoot(c)
  H.run(c, 0.05)
  c.g:remove_player(c.enemies[1])             -- target leaves -> unconfirmed(target_lost)
  H.run(c, 0.3)
  T.eq(H.stats(c).unconfirmed, 1)
  T.eq(c.inst.engine.reasons.target_lost, 1)
  c.J.signals.on_local_bullet_confirmed:Fire(c.enemies[1], { Name = "Head" }, "-85")
  H.settle(c)
  local s = H.stats(c)
  T.eq(s.unconfirmed, 0); T.eq(s.hits, 1)
  T.is_nil(c.inst.engine.reasons.target_lost, "the stale reason must be withdrawn too")
  H.check_invariant(c, T)
end)

T.test("a confirmation beyond confirm_horizon does not promote anything", function()
  local c = H.standard({ ping = 32, config = { confirm_horizon = 0.5 } })
  H.run(c, 3)
  H.shoot(c)
  H.settle(c, 1.2)
  T.eq(H.stats(c).misses, 1)
  c.J.signals.on_local_bullet_confirmed:Fire(c.enemies[1], { Name = "Head" }, "-85")
  H.run(c, 0.5)
  T.eq(H.stats(c).misses, 1, "too old to attribute")
  T.eq(H.stats(c).hits, 0)
  T.eq(c.inst.engine.counters.confirm_unmatched, 1)
end)

T.test("promotion never double counts: one confirmation, one hit", function()
  local c = H.standard({ ping = 32 })
  H.run(c, 3)
  H.shoot(c)
  H.run(c, 0.3)
  for i = 1, 4 do                              -- pellets of the same shot confirm together
    c.J.signals.on_local_bullet_confirmed:Fire(c.enemies[1], { Name = "Head" }, "-20")
  end
  H.settle(c)
  local s = H.stats(c)
  T.eq(s.attempted, 1); T.eq(s.hits, 1); T.eq(s.misses, 0)
  T.eq(c.inst.engine.counters.promoted, 1)
  H.check_invariant(c, T)
end)

T.test("an already-confirmed hit is never promoted again", function()
  local c = H.standard({ ping = 32 })
  H.run(c, 3)
  H.shoot(c)
  confirm(c, c.enemies[1], 0.1)                -- inside the window: a normal hit
  H.run(c, 1)
  T.eq(H.stats(c).hits, 1)
  T.eq(c.inst.engine.counters.promoted, 0)
  c.J.signals.on_local_bullet_confirmed:Fire(c.enemies[1], { Name = "Head" }, "-85")
  H.settle(c)
  T.eq(H.stats(c).hits, 1, "a second confirmation must not add a hit")
  H.check_invariant(c, T)
end)

T.test("the most recent eligible shot is the one corrected", function()
  local c = H.standard({ ping = 32 })
  H.run(c, 3)
  H.shoot(c); H.run(c, 0.6)                    -- shot A, expires
  H.shoot(c); H.run(c, 0.35)                   -- shot B, expires
  T.eq(H.stats(c).misses, 2)
  local b = c.inst.engine.last_shot
  c.J.signals.on_local_bullet_confirmed:Fire(c.enemies[1], { Name = "Head" }, "-85")
  H.settle(c)
  T.eq(H.stats(c).hits, 1)
  T.eq(b.outcome, "hit", "the newer shot is the plausible one")
  H.check_invariant(c, T)
end)

T.test("the report names the promotions", function()
  local c = H.standard({ ping = 32 })
  H.run(c, 3)
  H.shoot(c)
  confirm(c, c.enemies[1], 0.31)
  H.settle(c)
  T.contains(c.inst.report(), "promoted after their window closed: 1")
end)

return true
