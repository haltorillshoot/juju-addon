-- Juju's native bullet confirmation (on_local_bullet_confirmed(player, part, "-15")).
-- Payload shape and ordering were OBSERVED LIVE; the mock reproduces them.
local T = require("tf")
local H = require("harness")
local Signal = H.Mock.Signal

T.suite("21 Juju native hit confirmation")

local function confirm(c, enemy, delay, dmg)
  c.sim.task.delay(delay, function()
    c.J.signals.on_local_bullet_confirmed:Fire(enemy, { Name = "HumanoidRootPart" }, tostring(dmg or -15))
  end)
end

T.test("live order (health drops, Juju confirms ~85ms later): ONE hit, marked as confirmed", function()
  local c = H.standard()
  H.shoot_hit(c, c.enemies[1], 0.07, 15)
  confirm(c, c.enemies[1], 0.155)
  H.settle(c)
  local s = H.stats(c)
  T.eq(s.hits, 1); T.eq(s.confirmed_hits, 1); T.eq(s.misses, 0)
  T.eq(c.inst.engine.counters.corroborated, 1)
  T.eq(c.inst.world.juju_confirm_hooked, true)
  H.check_invariant(c, T)
end)

T.test("confirmation without a preceding health event still resolves the shot as a hit", function()
  local c = H.standard()
  H.shoot(c)
  confirm(c, c.enemies[1], 0.09)
  H.settle(c)
  local s = H.stats(c)
  T.eq(s.hits, 1); T.eq(s.confirmed_hits, 1)
  T.near(c.inst.engine.last_shot.latency, 0.09, 1e-6)
  H.check_invariant(c, T)
end)

T.test("pellet confirmations arriving together count the shot once and never resolve the NEXT shot", function()
  local c = H.standard()
  H.shoot_hit(c, c.enemies[1], 0.07, 15)
  for i = 0, 3 do confirm(c, c.enemies[1], 0.155 + i * 0.003) end    -- 4 pellets confirmed
  H.run(c, 0.1)
  H.shoot(c)                                                          -- next shot, no damage at all
  H.settle(c)
  local s = H.stats(c)
  T.eq(s.attempted, 2)
  T.eq(s.hits, 1, "the second shot must stay a miss")
  T.eq(s.misses, 1)
  T.eq(s.confirmed_hits, 1)
  T.eq(c.inst.engine.counters.confirm_pellets, 3)
  H.check_invariant(c, T)
end)

T.test("a health-inferred hit that Juju never confirms is reported as inferred-only", function()
  local c = H.standard()
  H.shoot_hit(c, c.enemies[1], 0.07, 15)          -- e.g. somebody else's damage
  H.settle(c)
  local s = H.stats(c)
  T.eq(s.hits, 1); T.eq(s.confirmed_hits, 0)
  T.contains(c.inst.report(), "confirmed by Juju's own bullet signal: 0 of 1")
  T.contains(table.concat(c.inst.ui:lines(), "\n"), "Juju-conf 0/1")
end)

T.test("a confirmation with no shot to attach to is counted, never turned into a hit", function()
  local c = H.standard()
  c.J.signals.on_local_bullet_confirmed:Fire(c.enemies[1], { Name = "Head" }, "-15")
  H.run(c, 1)
  T.eq(H.stats(c).hits, 0)
  T.eq(c.inst.engine.counters.confirm_unmatched, 1)
end)

T.test("a confirmation for an old, already-expired shot cannot revive it", function()
  local c = H.standard()
  H.shoot(c); H.run(c, 3)
  c.J.signals.on_local_bullet_confirmed:Fire(c.enemies[1], { Name = "Head" }, "-15")
  H.run(c, 1)
  T.eq(H.stats(c).hits, 0); T.eq(H.stats(c).misses, 1)
end)

T.test("a hit deferred for lack of fire evidence is released by Juju's confirmation", function()
  local c = H.standard({ ammo = 2, enemies = 1 })
  H.shoot(c); c.tool.ammo:SetValue(1); H.settle(c, 1); c.tool.ammo:SetValue(2)       -- validate the ammo source
  local before = H.stats(c).hits
  H.shoot(c)                                       -- no decrement seen ...
  H.damage_after(c, c.enemies[1], 0.07, 15)        -- ... damage ...
  confirm(c, c.enemies[1], 0.155)                  -- ... but Juju says the bullet hit
  H.settle(c)
  T.eq(H.stats(c).hits, before + 1)
  T.eq(H.stats(c).not_fired, 0)
  H.check_invariant(c, T)
end)

T.test("garbage payloads are ignored without errors", function()
  local c = H.standard()
  local sig = c.J.signals.on_local_bullet_confirmed
  sig:Fire(); sig:Fire(nil, nil, nil); sig:Fire("x", 1, {}); sig:Fire(c.enemies[1], nil, "not a number")
  H.run(c, 1)
  T.eq(#Signal.handler_errors, 0)
  T.eq(c.inst.errors, 0)
  T.eq(H.stats(c).hits, 0)
end)

T.test("use_juju_signals=false: signal not hooked, health-based detection unchanged", function()
  local c = H.standard({ config = { use_juju_signals = false } })
  T.falsy(c.inst.world.juju_confirm_hooked)
  T.eq(c.J.signals.on_local_bullet_confirmed.live, 0)
  H.shoot_hit(c, c.enemies[1], 0.07, 15); H.settle(c)
  T.eq(H.stats(c).hits, 1)
end)

T.test("a Juju build without the signal works as before", function()
  local c = H.standard({ pre = function(x) x.J.signals.on_local_bullet_confirmed = nil end })
  T.falsy(c.inst.world.juju_confirm_hooked)
  H.shoot_hit(c, c.enemies[1], 0.07, 15); H.settle(c)
  T.eq(H.stats(c).hits, 1)
  T.contains(c.inst.report(), "not available/disabled")
end)

T.test("the listener is released on unload and on reset the counters restart", function()
  local base = Signal.live_total
  local c = H.standard()
  H.run(c, 1)
  T.eq(c.J.signals.on_local_bullet_confirmed.live, 1)
  c.J.user_set("Hit Checker", "Reset stats", true)
  T.eq(c.inst.engine.counters.juju_confirms, 0)
  c.J.unload()
  T.eq(c.J.signals.on_local_bullet_confirmed.live, 0)
  T.eq(Signal.live_total, base)
end)

return true
