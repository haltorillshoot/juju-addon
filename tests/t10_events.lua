local T = require("tf")
local H = require("harness")
local Signal = H.Mock.Signal

T.suite("10 Event handling")

T.test("ammo decrement arriving just BEFORE the activation (handler order) still matches", function()
  local c = H.standard({ ammo = 2 })
  c.tool.ammo:SetValue(1)            -- game handler ran first
  H.shoot(c)                         -- our Activated handler second, same instant
  H.settle(c)
  local s = H.stats(c)
  T.eq(s.fired, 1); T.eq(s.misses, 1); T.eq(s.not_fired, 0)
  T.eq(c.inst.engine.counters.fire_unmatched, 1)
  T.eq(c.inst.engine.counters.fires_matched, 1)
end)

T.test("ammo decrement long before the activation does not count as that shot's fire", function()
  local c = H.standard({ ammo = 2 })
  c.tool.ammo:SetValue(1)
  H.run(c, 0.5)
  H.shoot(c)
  H.settle(c)
  T.eq(H.stats(c).not_fired, 1)
end)

T.test("ammo decrement with no attempt at all is counted, never invented into a shot", function()
  local c = H.standard({ ammo = 2 })
  c.tool.ammo:SetValue(1)
  H.settle(c)
  T.eq(H.stats(c).attempted, 0)
  T.eq(c.inst.engine.counters.fire_unmatched, 1)
end)

T.test("10 rapid shots 100ms apart: every one tracked and credited in FIFO order", function()
  local c = H.standard()
  for i = 1, 10 do
    H.shoot_hit(c, c.enemies[1], 0.07, 2)
    H.run(c, 0.1)
  end
  H.settle(c)
  local s = H.stats(c)
  T.eq(s.attempted, 10); T.eq(s.hits, 10); T.eq(s.unconfirmed, 0); T.eq(s.misses, 0)
  H.check_invariant(c, T)
end)

T.test("garbage HealthChanged arguments are ignored without errors", function()
  local c = H.standard()
  local hum = c.enemies[1].hum
  H.shoot(c)
  hum.HealthChanged:Fire(nil)
  hum.HealthChanged:Fire("90")
  hum.HealthChanged:Fire(0 / 0)
  hum.HealthChanged:Fire({})
  H.settle(c)
  T.eq(H.stats(c).hits, 0)
  T.eq(#Signal.handler_errors, 0, "handler raised: " .. tostring(Signal.handler_errors[1]))
  T.eq(c.inst.errors, 0)
end)

T.test("a throwing engine call is isolated: error counted, later events still work", function()
  local c = H.standard()
  local eng = c.inst.engine
  local real = eng.register_damage
  local calls = 0
  eng.register_damage = function(self, info)
    calls = calls + 1
    if calls == 1 then error("boom") end
    return real(self, info)
  end
  H.shoot(c)
  H.damage_after(c, c.enemies[1], 0.07, 10)        -- throws inside the handler
  H.run(c, 1)
  T.eq(c.inst.errors, 1)
  H.shoot(c)
  H.damage_after(c, c.enemies[1], 0.07, 10)
  H.settle(c)
  T.eq(H.stats(c).hits, 1, "second damage handled normally")
end)

T.test("engine: out-of-order timestamps are not attributed (damage before the shot)", function()
  local c = H.standard()
  local eng = c.inst.engine
  c.sim:advance(5)
  eng:register_shot({ t = 5.0, weapon = { key = "x", name = "x", is_dbs = false }, candidates = { [9] = true }, ncand = 1, ping_ms = 60 })
  local r = eng:register_damage({ t = 4.9, uid = 9, amount = 10 })
  T.eq(r, "unattributed")
  T.eq(eng.last_shot.state, "pending")
end)

T.test("engine: clock going backwards is treated as a duplicate, not time travel", function()
  local c = H.standard()
  local eng = c.inst.engine
  local w = { key = "x", name = "x", is_dbs = false }
  c.sim:advance(10)
  eng:register_shot({ t = 10, weapon = w, candidates = { [9] = true }, ncand = 1 })
  local s, why = eng:register_shot({ t = 9.5, weapon = w, candidates = { [9] = true }, ncand = 1 })
  T.is_nil(s); T.eq(why, "deduped")
  T.eq(eng.counters.clock_anomaly, 1)
end)

T.test("engine: burst boundary — events inside burst_gap merge, outside it start a new burst", function()
  local c = H.standard()
  local eng = c.inst.engine
  local gap = c.inst.cfg.burst_gap
  local w = { key = "x", name = "x", is_dbs = false }
  c.sim:advance(1)
  eng:register_shot({ t = 1, weapon = w, candidates = { [9] = true }, ncand = 1, ping_ms = 10 })
  eng:register_shot({ t = 1.1, weapon = w, candidates = { [9] = true }, ncand = 1, ping_ms = 10 })
  T.eq(eng:register_damage({ t = 1.1, uid = 9, amount = 5 }), "hit")
  T.eq(eng:register_damage({ t = 1.1 + gap * 0.9, uid = 9, amount = 5 }), "burst")
  T.eq(eng:register_damage({ t = 1.1 + gap * 0.9 + gap * 1.5, uid = 9, amount = 5 }), "hit")
end)

T.test("engine: invalid damage arguments are counted, not crashed on", function()
  local c = H.standard()
  local eng = c.inst.engine
  T.eq(eng:register_damage({ uid = nil, amount = 5 }), "invalid")
  T.eq(eng:register_damage({ uid = 1, amount = 0 }), "invalid")
  T.eq(eng:register_damage({ uid = 1, amount = -3 }), "invalid")
  T.eq(eng:register_damage({ uid = 1, amount = 0 / 0 }), "invalid")
  T.eq(eng:register_damage({ uid = 1, amount = "x" }), "invalid")
  T.eq(eng.counters.invalid_events, 5)
end)

T.test("a duplicate PlayerAdded for an existing player does not create a second tracker", function()
  local c = H.standard({ enemies = 1 })
  local before = Signal.live_total
  c.g.PlayerAdded:Fire(c.enemies[1])
  c.g.PlayerAdded:Fire(c.enemies[1])
  T.eq(Signal.live_total, before)
  T.eq(c.inst.world:target_count(), 1)
end)

T.test("a duplicate CharacterAdded does not stack Humanoid listeners", function()
  local c = H.standard({ enemies = 1 })
  local hum = c.enemies[1].hum
  T.eq(hum.HealthChanged.live, 1)
  c.enemies[1].CharacterAdded:Fire(c.enemies[1].Character)
  c.enemies[1].CharacterAdded:Fire(c.enemies[1].Character)
  T.eq(hum.HealthChanged.live, 1)
  T.eq(hum.Died.live, 1)
  H.shoot_hit(c, c.enemies[1], 0.07, 10); H.settle(c)
  T.eq(H.stats(c).hits, 1, "and damage is not double counted")
end)

T.test("the expiry timer is cancelled when a hit resolves the shot early", function()
  local c = H.standard()
  H.run(c, 1)
  local cancels = c.sim.stats.cancels
  H.shoot_hit(c, c.enemies[1], 0.07, 10)
  H.run(c, 0.1)
  T.eq(H.stats(c).hits, 1)
  T.ok(c.sim.stats.cancels > cancels, "the expiry timer must be cancelled explicitly, not left to fire")
end)

T.test("disabling tracking mid-flight lets pending shots finish cleanly", function()
  local c = H.standard()
  H.shoot(c)
  c.J.user_set("Hit Checker", "Enabled", false)
  H.shoot(c)                                    -- ignored while disabled
  H.settle(c)
  local s = H.stats(c)
  T.eq(s.attempted, 1)
  T.eq(s.pending, 0)
  H.check_invariant(c, T)
end)

return true
