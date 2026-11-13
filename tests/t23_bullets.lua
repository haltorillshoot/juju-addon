-- Gun shot attempts via Juju's on_player_bullet_fired.
-- LIVE: Hood Customs guns do not fire Tool.Activated (melee does); this signal fires once per
-- bullet/pellet, and a two-client test showed each client receives only its own bullets.
local T = require("tf")
local H = require("harness")
local Signal = H.Mock.Signal

T.suite("23 Gun shots via bullet signal")

local function fire(c, n, gap)
  for i = 1, (n or 1) do
    c.J.signals.on_player_bullet_fired:Fire({ Name = "BULLET_RAYS" }, { Name = "GunBeam" }, nil, false)
    if gap and i < (n or 1) then c.sim:advance(gap) end
  end
end

T.test("one trigger pull with 3 simultaneous pellets is ONE shot attempt", function()
  local c = H.standard()
  fire(c, 3)
  H.settle(c)
  local s = H.stats(c)
  T.eq(s.attempted, 1)
  T.eq(s.misses, 1)
  T.eq(c.inst.world.counts.bullets_seen, 3)
  T.eq(c.inst.engine.last_shot.pellets, 3)
  T.eq(c.inst.engine.last_shot.source, "bullet")
  H.check_invariant(c, T)
end)

T.test("two barrels separated by more than pellet_gap are two shots", function()
  local c = H.standard()
  fire(c, 3)
  c.sim:advance(0.3)
  fire(c, 3)
  H.settle(c)
  T.eq(H.stats(c).attempted, 2)
  H.check_invariant(c, T)
end)

T.test("pellets spread within one pellet_gap of the pull still coalesce", function()
  local c = H.standard()
  fire(c, 4, 0.012)                     -- 36ms total span, inside the 50ms pellet_gap
  H.settle(c)
  T.eq(H.stats(c).attempted, 1)
  T.eq(c.inst.engine.last_shot.pellets, 4)
end)

T.test("the pull window is measured from its start, so a stream cannot chain forever", function()
  local c = H.standard()
  fire(c, 30, 0.02)                     -- 20ms apart for 600ms: must NOT become one giant shot
  H.settle(c)
  local s = H.stats(c)
  T.ok(s.attempted >= 8, "a long stream must split into several shots, got " .. s.attempted)
  T.eq(c.inst.world.counts.bullets_seen, 30)
  H.check_invariant(c, T)
end)

T.test("a gun shot is confirmed by the Juju hit signal like any other", function()
  local c = H.standard()
  fire(c, 3)
  c.sim.task.delay(0.15, function()
    c.J.signals.on_local_bullet_confirmed:Fire(c.enemies[1], { Name = "Head" }, "-85")
  end)
  H.settle(c)
  local s = H.stats(c)
  T.eq(s.hits, 1); T.eq(s.confirmed_hits, 1); T.eq(s.misses, 0)
  H.check_invariant(c, T)
end)

T.test("pellets arriving after a fast hit do not open a second shot", function()
  local c = H.standard()
  fire(c, 1)
  c.J.signals.on_local_bullet_confirmed:Fire(c.enemies[1], { Name = "Head" }, "-85")  -- resolves at once
  T.eq(H.stats(c).hits, 1)
  fire(c, 2)                            -- remaining pellets of the same pull
  H.settle(c)
  T.eq(H.stats(c).attempted, 1, "late pellets must not count as a new shot")
  H.check_invariant(c, T)
end)

T.test("no weapon equipped: bullets are ignored rather than invented into shots", function()
  local c = H.standard({ tool = false })
  fire(c, 3)
  H.settle(c)
  T.eq(H.stats(c).attempted, 0)
  T.eq(#c.sim.errors, 0)
end)

T.test("melee still works through Tool.Activated, and the two sources do not double count", function()
  local c = H.standard({ tool_name = "[Knife]" })
  H.shoot(c)                            -- Activated (melee)
  fire(c, 1)                            -- a bullet in the same instant must not add a shot
  H.settle(c)
  local s = H.stats(c)
  T.eq(s.attempted, 1)
  T.eq(c.inst.engine.last_shot.source, "activated")
  H.check_invariant(c, T)
end)

T.test("shots are attributed to the equipped weapon and bucketed", function()
  local c = H.standard()
  fire(c, 2)
  H.settle(c)
  T.eq(H.stats(c, "weapon:doublebarrelsg").attempted, 1)
  T.eq(c.inst.engine.last_shot.weapon.is_dbs, true)
end)

T.test("real tool name [DoubleBarrel] is recognised as the Double Barrel", function()
  local c = H.standard({ tool_name = "[DoubleBarrel]" })
  T.eq(c.inst.world.current.weapon.key, "doublebarrel")
  T.ok(c.inst.world.current.weapon.is_dbs)
  c.J.user_set("Auto Mode", "Auto Mode DBS", true)
  T.eq(c.inst.auto.state, "ACTIVE")
  fire(c, 2)
  H.settle(c)
  T.eq(H.stats(c, "mode:auto").attempted, 1)
end)

T.test("use_bullet_signal=false falls back to Activated only", function()
  local c = H.standard({ config = { use_bullet_signal = false } })
  T.falsy(c.inst.world.bullet_hooked)
  T.eq(c.J.signals.on_player_bullet_fired.live, 0)
  fire(c, 3)
  H.settle(c)
  T.eq(H.stats(c).attempted, 0)
end)

T.test("a Juju build without the signal still works", function()
  local c = H.standard({ pre = function(x) x.J.signals.on_player_bullet_fired = nil end })
  T.falsy(c.inst.world.bullet_hooked)
  T.contains(c.inst.report(), "shot source for guns): not available/disabled")
  H.shoot(c); H.settle(c)
  T.eq(H.stats(c).attempted, 1)
end)

T.test("the listener is released on unload", function()
  local base = Signal.live_total
  local c = H.standard()
  T.eq(c.J.signals.on_player_bullet_fired.live, 1)
  c.J.unload()
  T.eq(c.J.signals.on_player_bullet_fired.live, 0)
  T.eq(Signal.live_total, base)
end)

T.test("rapid automatic fire: 200 bullets in 20 pulls = 20 shots", function()
  local c = H.standard()
  for pull = 1, 20 do
    fire(c, 10, 0.004)
    c.sim:advance(0.2)
  end
  H.settle(c)
  T.eq(H.stats(c).attempted, 20)
  T.eq(c.inst.world.counts.bullets_seen, 200)
  H.check_invariant(c, T)
end)

return true
