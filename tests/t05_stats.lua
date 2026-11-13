local T = require("tf")
local H = require("harness")

T.suite("05 Hit statistics")

-- deterministic LCG so the "random" scenario is reproducible on every Lua
local function lcg(seed)
  local s = seed
  return function()
    s = (s * 1103515245 + 12345) % 2147483648
    return s / 2147483648
  end
end

T.test("statistics equal exactly what a scripted session did (300 shots)", function()
  local c = H.standard({ enemies = 3 })
  local rnd = lcg(42)
  local exp_hit, exp_miss = 0, 0
  for i = 1, 300 do
    H.shoot(c)
    if rnd() < 0.4 then
      H.damage_after(c, c.enemies[1 + (i % 3)], 0.06 + rnd() * 0.1, 1)
      exp_hit = exp_hit + 1
    else
      exp_miss = exp_miss + 1
    end
    H.run(c, 1.0)
    if i % 25 == 0 then H.check_invariant(c, T) end
  end
  local s = H.stats(c)
  T.eq(s.attempted, 300)
  T.eq(s.hits, exp_hit, "hits")
  T.eq(s.misses, exp_miss, "misses")
  T.eq(s.unconfirmed + s.not_fired + s.pending, 0)
  T.near(s.hit_pct, exp_hit / (exp_hit + exp_miss) * 100, 1e-9)
  T.near(s.reg_pct, exp_hit / 300 * 100, 1e-9)
  H.clean_sim(c, T)
end)

T.test("hit% uses resolved shots only; unconfirmed/not_fired/pending are excluded", function()
  local c = H.standard({ enemies = 1 })
  H.shoot_hit(c, c.enemies[1], 0.07, 10); H.run(c, 1)           -- hit
  H.shoot(c); H.run(c, 1)                                        -- miss
  c.g:remove_player(c.enemies[1])
  H.shoot(c); H.run(c, 1)                                        -- unconfirmed (no target)
  H.shoot(c)                                                     -- pending
  local s = H.stats(c)
  T.eq(s.hits, 1); T.eq(s.misses, 1); T.eq(s.unconfirmed, 1); T.eq(s.pending, 1)
  T.near(s.hit_pct, 50, 1e-9)
  T.near(s.reg_pct, 25, 1e-9)
  H.check_invariant(c, T)
end)

T.test("duplicate activation events inside dedupe_eps count once", function()
  local c = H.standard()
  H.shoot(c); H.shoot(c); H.shoot(c)
  H.run(c, 1)
  local s = H.stats(c)
  T.eq(s.attempted, 1)
  T.eq(s.deduped, 2)
  H.check_invariant(c, T)
end)

T.test("buckets: per-weapon and per-mode statistics add up to the total", function()
  local c = H.standard({ enemies = 1 })
  local rev = c.g:give_tool(c.me, "[Revolver]")
  H.shoot_hit(c, c.enemies[1], 0.07, 10); H.run(c, 1)           -- DBS hit (manual)
  c.g:unequip(c.me, c.tool); c.g:equip(c.me, rev)
  H.shoot(c, rev); H.run(c, 1)                                   -- revolver miss
  local all = H.stats(c, "all")
  local dbs = H.stats(c, "weapon:doublebarrelsg")
  local rv = H.stats(c, "weapon:revolver")
  T.eq(all.attempted, 2)
  T.eq(dbs.attempted + rv.attempted, all.attempted)
  T.eq(dbs.hits, 1); T.eq(rv.misses, 1)
  T.eq(H.stats(c, "mode:manual").attempted, 2)
  T.eq(H.stats(c, "mode:auto").attempted, 0)
end)

T.test("hit latency statistics are recorded", function()
  local c = H.standard()
  local lats = { 0.06, 0.08, 0.10 }
  for _, l in ipairs(lats) do H.shoot_hit(c, c.enemies[1], l, 5); H.run(c, 1) end
  local s = H.stats(c)
  T.near(s.lat_avg, 0.08, 1e-9)
  T.near(s.lat_min, 0.06, 1e-9)
  T.near(s.lat_max, 0.10, 1e-9)
end)

T.test("reset zeroes everything and stale timers cannot resurrect old shots", function()
  local c = H.standard()
  H.shoot(c)
  H.run(c, 0.1)
  c.J.user_set("Hit Checker", "Reset stats", true)
  H.run(c, 3)
  local s = H.stats(c)
  T.eq(s.attempted, 0); T.eq(s.misses, 0); T.eq(s.pending, 0)
  T.eq(c.inst.engine:pending_count(), 0)
  H.clean_sim(c, T)
  -- and counting works again afterwards
  H.shoot_hit(c, c.enemies[1], 0.07, 10); H.run(c, 1)
  T.eq(H.stats(c).hits, 1)
  H.check_invariant(c, T)
end)

T.test("reset toggle is momentary: it flips itself back to false", function()
  local c = H.standard()
  c.J.user_set("Hit Checker", "Reset stats", true)
  T.eq(c.J.element("Hit Checker", "Reset stats").value, false)
end)

T.test("exported jhc_* flags track the live statistics", function()
  local c = H.standard()
  H.shoot_hit(c, c.enemies[1], 0.07, 10); H.run(c, 1)
  H.shoot(c); H.run(c, 1)
  H.run(c, 0.5)
  T.eq(c.J.flags.jhc_shots, 2)
  T.eq(c.J.flags.jhc_hits, 1)
  T.eq(c.J.flags.jhc_misses, 1)
  T.eq(c.J.flags.jhc_hit_pct, 50)
end)

T.test("no resolved shots -> hit% is nil (n/a), never 0/0 NaN", function()
  local c = H.standard()
  local s = H.stats(c)
  T.is_nil(s.hit_pct)
  T.is_nil(s.reg_pct)
  T.contains(c.inst.report(), "n/a")
end)

return true
