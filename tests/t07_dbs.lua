local T = require("tf")
local H = require("harness")
local Weapon = require("weapon")
local Config = require("config")

T.suite("07 Double Barrel Shotgun")

T.test("identification: name variants of the Double Barrel Shotgun", function()
  local cfg = Config.new().values
  local yes = { "[Double-Barrel SG]", "Double-Barrel SG", "Double Barrel Shotgun", "DoubleBarrel",
    "double_barrel", "[Double-Barrel SG] - 2 | 2", "DOUBLE BARREL", "DBSG" }
  for _, n in ipairs(yes) do
    T.ok(Weapon.identify(n, cfg).is_dbs, "should be DBS: " .. n)
  end
  local no = { "[Revolver]", "Shotgun", "[Tactical Shotgun]", "Drum Shotgun", "Pump", "Sawed-Off",
    "Double Jump", "Knife", "[SMG]" }
  for _, n in ipairs(no) do
    T.falsy(Weapon.identify(n, cfg).is_dbs, "should NOT be DBS: " .. n)
  end
end)

T.test("aliases are configurable (in-game name is unverified)", function()
  local c = H.standard({ tool_name = "[Sawed Off]", config = { weapon_aliases = { "sawed", "Cut Down" } } })
  T.ok(c.inst.world.current.weapon.is_dbs)
  T.eq(c.inst.cfg.weapon_aliases[2], "cutdown", "alias normalised")
end)

T.test("two barrels, 400ms apart, both hit -> 2 hits, windows do not overlap", function()
  local c = H.standard()
  H.shoot_hit(c, c.enemies[1], 0.07, 30)
  H.run(c, 0.4)
  H.shoot_hit(c, c.enemies[1], 0.07, 30)
  H.settle(c)
  local s = H.stats(c, "weapon:doublebarrelsg")
  T.eq(s.attempted, 2); T.eq(s.hits, 2); T.eq(s.unconfirmed, 0)
  H.check_invariant(c, T)
end)

T.test("two barrels back-to-back (50ms) with distinguishable damage bursts -> 2 hits", function()
  local c = H.standard()
  H.shoot(c)
  H.run(c, 0.05)
  H.shoot(c)
  H.damage_after(c, c.enemies[1], 0.02, 30)    -- t=0.07  (barrel 1)
  H.damage_after(c, c.enemies[1], 0.07, 30)    -- t=0.12  (barrel 2)
  H.settle(c)
  local s = H.stats(c)
  T.eq(s.hits, 2, "both barrels confirmed")
  T.eq(s.unconfirmed, 0)
  H.check_invariant(c, T)
end)

T.test("two barrels back-to-back whose damage coalesces -> 1 hit + 1 ambiguous, never 2 hits", function()
  local c = H.standard()
  H.shoot(c)
  H.run(c, 0.05)
  H.shoot(c)
  H.damage_after(c, c.enemies[1], 0.02, 30)
  H.damage_after(c, c.enemies[1], 0.035, 30)   -- 15ms later: same burst
  H.settle(c)
  local s = H.stats(c)
  T.eq(s.hits, 1)
  T.eq(s.unconfirmed, 1)
  T.eq(s.misses, 0)
end)

T.test("first barrel hits, second misses", function()
  local c = H.standard()
  H.shoot_hit(c, c.enemies[1], 0.07, 30)
  H.run(c, 0.5)
  H.shoot(c)
  H.settle(c)
  local s = H.stats(c)
  T.eq(s.hits, 1); T.eq(s.misses, 1)
  T.near(s.hit_pct, 50, 1e-9)
end)

T.test("8 pellets from one barrel are one hit", function()
  local c = H.standard()
  H.shoot(c)
  for i = 1, 8 do H.damage_after(c, c.enemies[1], 0.07 + (i % 3) * 0.002, 8) end
  H.settle(c)
  T.eq(H.stats(c).hits, 1)
  T.near(H.stats(c).damage, 64, 1e-9)
end)

T.test("with an ammo source: shells decrement per barrel, an empty gun is not_fired", function()
  local c = H.standard({ ammo = 2 })
  c.J.ping = 60
  for i = 1, 2 do
    H.shoot(c)
    c.tool.ammo:SetValue(c.tool.ammo.Value - 1)
    H.damage_after(c, c.enemies[1], 0.07, 25)
    H.run(c, 0.6)
  end
  T.eq(c.tool.ammo.Value, 0)
  H.shoot(c)                         -- click on an empty double barrel
  H.settle(c)
  local s = H.stats(c)
  T.eq(s.attempted, 3); T.eq(s.hits, 2); T.eq(s.not_fired, 1); T.eq(s.misses, 0); T.eq(s.fired, 2)
  H.check_invariant(c, T)
end)

T.test("cooldown click (second activation, no ammo change) is not_fired, not a miss", function()
  local c = H.standard({ ammo = 2 })
  H.shoot(c)
  c.tool.ammo:SetValue(1)
  H.run(c, 0.1)
  H.shoot(c)                         -- game ignored it: no decrement
  H.settle(c)
  local s = H.stats(c)
  T.eq(s.attempted, 2); T.eq(s.misses, 1); T.eq(s.not_fired, 1)
end)

T.test("inter-shot interval statistics are kept per weapon", function()
  local c = H.standard()
  H.shoot(c); H.run(c, 0.3)
  H.shoot(c); H.run(c, 0.5)
  H.shoot(c); H.run(c, 1.0)
  local iv = c.inst.engine:interval_stats("doublebarrelsg")
  T.eq(iv.n, 2)
  T.near(iv.min, 0.3, 1e-9)
  T.near(iv.last, 0.5, 1e-9)
  T.contains(c.inst.report(), "interval(min/med)")
end)

T.test("DBS statistics are isolated from other weapons", function()
  local c = H.standard({ enemies = 1 })
  local rev = c.g:give_tool(c.me, "[Revolver]")
  H.shoot_hit(c, c.enemies[1], 0.07, 10); H.run(c, 1)
  c.g:unequip(c.me, c.tool); c.g:equip(c.me, rev)
  H.shoot(c, rev); H.run(c, 1)
  H.shoot(c, rev); H.run(c, 1)
  T.eq(H.stats(c, "weapon:doublebarrelsg").attempted, 1)
  T.eq(H.stats(c, "weapon:revolver").attempted, 2)
  T.eq(H.stats(c, "weapon:revolver").hits, 0)
end)

T.test("DBS shots during a latency spike are classified, not guessed", function()
  local c = H.standard({ enemies = 1 })
  H.run(c, 8)
  c.J.ping = 1200
  H.shoot(c)                         -- spike at shot time
  H.run(c, 2.5)
  c.J.ping = 60
  local s = H.stats(c)
  T.eq(s.misses, 0)
  T.eq(s.unconfirmed, 1)
end)

return true
