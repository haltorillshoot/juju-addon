-- Regression tests for defects found by the independent code review (one test per finding).
local T = require("tf")
local H = require("harness")
local Weapon = require("weapon")
local Config = require("config")

T.suite("18 Review regressions")

local function eng_shot(c, t, over)
  local info = { t = t, weapon = { key = "x", name = "x", is_dbs = false }, candidates = { [9] = true },
    ncand = 1, ping_ms = 10 }
  for k, v in pairs(over or {}) do info[k] = v end
  return c.inst.engine:register_shot(info)
end

-- R1 ------------------------------------------------------------------------------------
T.test("R1 an unrelated damage burst just before a shot cannot swallow the shot's own damage", function()
  local c = H.standard()
  local eng = c.inst.engine
  c.sim:advance(1)
  T.eq(eng:register_damage({ t = 1.000, uid = 9, amount = 5 }), "unattributed")   -- someone else
  eng:register_shot({ t = 1.010, weapon = { key = "x", name = "x", is_dbs = false },
    candidates = { [9] = true }, ncand = 1, ping_ms = 10 })
  T.eq(eng:register_damage({ t = 1.025, uid = 9, amount = 20 }), "hit", "must not be absorbed by the older burst")
  T.eq(eng:stats("all").hits, 1)
end)

T.test("R1 a burst cannot absorb damage that a NEWER shot could own (long burst_gap)", function()
  local c = H.standard({ config = { burst_gap = 0.1 } })
  H.shoot_hit(c, c.enemies[1], 0.07, 10)          -- A: damage at 0.07
  H.run(c, 0.10)
  H.shoot(c)                                       -- B fired at 0.10
  H.damage_after(c, c.enemies[1], 0.05, 10)        -- B's damage at 0.15, only 80ms after A's burst
  H.settle(c)
  T.eq(H.stats(c).hits, 2, "both shots confirmed")
  T.eq(H.stats(c).misses, 0)
end)

T.test("R1 a continuous damage stream is split into bounded bursts, not one endless burst", function()
  local c = H.standard()
  local eng = c.inst.engine
  c.sim:advance(1)
  for i = 0, 10 do eng:register_damage({ t = 1 + i * 0.02, uid = 9, amount = 1 }) end   -- 0..200ms, 20ms apart
  T.ok(eng.counters.unattributed_damage >= 2, "bursts: " .. eng.counters.unattributed_damage)
end)

T.test("R1 pellets of the same shot are still one burst after the fix", function()
  local c = H.standard()
  H.shoot(c)
  for i = 0, 7 do H.damage_after(c, c.enemies[1], 0.07 + i * 0.002, 3) end
  H.settle(c)
  T.eq(H.stats(c).hits, 1)
  T.eq(c.inst.engine.last_shot.damage_events, 8)
end)

-- R2 ------------------------------------------------------------------------------------
T.test("R2 the report detects a broken invariant (leaked pending shot)", function()
  local c = H.standard()
  H.shoot(c)
  T.ok(c.inst.engine:check_invariant())
  T.falsy(string.find(c.inst.report(), "INVARIANT BROKEN", 1, true))
  local shot = table.remove(c.inst.engine.pending)          -- simulate a leak: shot vanishes unresolved
  local ok, msg = c.inst.engine:check_invariant()
  T.falsy(ok); T.contains(msg, "pending")
  T.contains(c.inst.report(), "INVARIANT BROKEN")
  table.insert(c.inst.engine.pending, shot)
  T.ok(c.inst.engine:check_invariant())

  -- a leak that removes the shot from BOTH the list and the id index is caught only by the
  -- counters-vs-list comparison
  local leaked = table.remove(c.inst.engine.pending)
  c.inst.engine.by_id[leaked.id] = nil
  local ok2, msg2 = c.inst.engine:check_invariant()
  T.falsy(ok2)
  T.contains(msg2, "counters imply")
end)

-- R3 ------------------------------------------------------------------------------------
T.test("R3 constant-style names are never treated as the live ammo counter", function()
  local cfg = Config.new().values
  for _, n in ipairs({ "BulletSpeed", "MagazineSize", "ClipSize", "ShellCapacity", "ReserveAmmo", "TotalAmmo",
    "AmmoLimit", "BulletDamage", "FireRate" }) do
    T.falsy(Weapon.is_ammo_name(n, cfg), n)
  end
  for _, n in ipairs({ "Ammo", "CurrentAmmo", "AmmoCount", "Clip", "Shells", "Bullets" }) do
    T.ok(Weapon.is_ammo_name(n, cfg), n)
  end
end)

T.test("R3 a tool whose only numeric child is a constant gets no ammo source", function()
  local c = H.standard({ tool = false })
  local t = c.g:give_tool(c.me, "[Double-Barrel SG]", { ammo = 5, ammo_name = "BulletSpeed" })
  c.g:equip(c.me, t)
  T.is_nil(c.inst.world.current.ammo_kind)
  H.shoot(c, t); H.settle(c)
  T.eq(H.stats(c).misses, 1); T.eq(H.stats(c).not_fired, 0)
end)

T.test("R3 an 'Ammo'-named value that never changes cannot turn misses into not_fired", function()
  local c = H.standard({ ammo = 2 })
  for i = 1, 5 do H.shoot(c); H.run(c, 1) end
  T.eq(H.stats(c).misses, 5); T.eq(H.stats(c).not_fired, 0)
  T.falsy(c.inst.world.current.ammo_validated)
end)

-- R4b -----------------------------------------------------------------------------------
local function validated(c)           -- one calibrating shot: ammo drops, then is reloaded
  H.shoot(c)
  c.tool.ammo:SetValue(c.tool.ammo.Value - 1)
  H.settle(c, 1)
  c.tool.ammo:SetValue(2)
end

T.test("R4b damage on a click that never fired is not credited (validated ammo, no decrement)", function()
  local c = H.standard({ ammo = 2, enemies = 1 })
  validated(c)
  local before = H.stats(c)
  H.shoot(c)                                       -- cooldown click: no decrement
  H.damage_after(c, c.enemies[1], 0.07, 10)        -- somebody else's damage
  H.settle(c)
  local s = H.stats(c)
  T.eq(s.hits, before.hits, "no new hit")
  T.eq(s.not_fired, 1)
  T.eq(c.inst.engine.last_shot.reason, "damage_without_fire")
  H.check_invariant(c, T)
end)

T.test("R4b late ammo evidence (after the damage) still confirms the hit", function()
  local c = H.standard({ ammo = 2, enemies = 1 })
  validated(c)
  local before = H.stats(c).hits
  H.shoot(c)
  H.damage_after(c, c.enemies[1], 0.07, 10)        -- damage first ...
  c.sim.task.delay(0.10, function() c.tool.ammo:SetValue(1) end)   -- ... ammo replication a bit later
  H.settle(c)
  T.eq(H.stats(c).hits, before + 1)
  T.near(c.inst.engine.last_shot.latency, 0.07, 1e-6, "latency is the damage time, not the ammo time")
  H.check_invariant(c, T)
end)

-- R5 ------------------------------------------------------------------------------------
T.test("R5 a window shorter than the causal floor can never produce a 'miss'", function()
  local c = H.standard({ ping = 600, config = { window_min = 0.25, window_max = 0.25, window_default = 0.25 } })
  H.run(c, 3)
  H.shoot(c); H.settle(c)
  T.eq(H.stats(c).misses, 0)
  T.eq(c.inst.engine.last_shot.reason, "window_below_causal_floor")
end)

T.test("R5 hazardous config values are bounded by the schema", function()
  local cfg = Config.sanitize({ timer_late_tol = 0, burst_gap = 0.5, dedupe_eps = 0.5, late_grace = 5 })
  T.eq(cfg.timer_late_tol, 0.02); T.eq(cfg.burst_gap, 0.1); T.eq(cfg.dedupe_eps, 0.1); T.eq(cfg.late_grace, 2)
end)

-- R6 ------------------------------------------------------------------------------------
T.test("R6 damage after the deadline but before the expiry timer ran is 'late', not silently lost", function()
  local c = H.standard()
  c.sim:advance(10)
  local shot = eng_shot(c, 10, { ping_ms = 60 })
  local w = shot.window
  T.eq(c.inst.engine:register_damage({ t = 10 + w + 0.5 * c.inst.cfg.late_grace * w, uid = 9, amount = 5 }), "late")
  c.sim:advance(w + 0.5)
  T.eq(shot.outcome, "unconfirmed")
  T.eq(shot.reason, "late_damage")
  T.eq(c.inst.engine.counters.late_damage, 1)
  H.check_invariant(c, T)
end)

-- R7 ------------------------------------------------------------------------------------
T.test("R7 a ping spike that starts mid-window is seen at expiry", function()
  local c = H.standard()
  H.run(c, 8)
  H.shoot(c)                                       -- healthy at shot time
  H.run(c, 0.05)
  c.J.ping = 900                                   -- link degrades inside the window
  H.settle(c, 2)
  c.J.ping = 60
  T.eq(c.inst.engine.last_shot.outcome, "unconfirmed")
  T.eq(c.inst.engine.last_shot.reason, "degraded:ping_spike")
end)

-- R8 ------------------------------------------------------------------------------------
T.test("R8 elements without set_value: momentary buttons still work on every click", function()
  local c = H.standard({ pre = function(x) x.J.no_set_value = true end })
  T.ok(c.inst)
  H.shoot(c); H.run(c, 1)
  T.eq(H.stats(c).attempted, 1)
  c.J.user_set("Hit Checker", "Reset stats", true)       -- first click
  T.eq(H.stats(c).attempted, 0)
  H.shoot(c); H.run(c, 1)
  c.J.user_set("Hit Checker", "Reset stats", false)      -- the stuck toggle's second click sends false
  T.eq(H.stats(c).attempted, 0, "a click is a click, whatever value the toggle reports")
end)

T.test("R8 a host that fires callbacks with defaults while creating elements cannot clobber the config", function()
  local c = H.standard({ pre = function(x) x.J.fire_on_create = true end,
    config = { window_max = 1.2345, hud = true, auto_mode = true } })
  T.ok(c.inst)
  T.eq(c.inst.cfg.enabled, true)
  T.eq(c.inst.cfg.hud, true)
  T.eq(c.inst.cfg.window_max, 1.2345)
  T.eq(c.inst.cfg.auto_mode, true)
  H.shoot(c); H.settle(c)
  T.eq(H.stats(c).attempted, 1)
end)

-- R9 ------------------------------------------------------------------------------------
T.test("R9 jhc_loaded is cleared on unload", function()
  local c = H.standard()
  H.run(c, 1)
  T.eq(c.J.flags.jhc_loaded, true)
  c.J.unload()
  T.eq(c.J.flags.jhc_loaded, false)
end)

-- R10 -----------------------------------------------------------------------------------
T.test("R10 a local Humanoid that replicates late is still hooked (died context)", function()
  local c = H.boot({ pre = function(x)
    x.J.ping = 60
    x.g:spawn(x.me, { late_humanoid = true })
    local p = x.g:add_player("E", 101); x.g:spawn(p); x.enemies[1] = p
    x.tool = x.g:give_tool(x.me, "[Double-Barrel SG]")
    x.g:equip(x.me, x.tool)
  end })
  c.g:add_humanoid_late(c.me)
  H.shoot(c)
  c.me.hum:SetHealth(0)
  H.settle(c)
  T.eq(c.inst.engine.last_shot.reason, "died")
end)

-- R11 -----------------------------------------------------------------------------------
T.test("R11 a Drawing object that cannot be configured is removed, not leaked", function()
  local c = H.standard({ pre = function(x) x.drawing.fail_on = "Size" end })
  H.run(c, 1)
  T.ok(c.inst.ui.hud_failed)
  T.eq(c.drawing.live, 0, "half-configured Drawing objects left on screen")
  T.ok(c.drawing.created >= 1)
end)

-- R12 -----------------------------------------------------------------------------------
T.test("R12 a handler that fails on every event does not flood the console", function()
  local c = H.standard()
  c.inst.engine.register_damage = function() error("always broken") end
  local before = #c.env.output
  for i = 1, 1000 do c.enemies[1].hum:SetHealth(100 - i * 0.05) end
  T.eq(c.inst.errors, 1000)
  T.ok(#c.env.output - before <= 20, "console lines: " .. (#c.env.output - before))
end)

-- clock self-check ------------------------------------------------------------------------
T.test("clock self-check: a clock that disagrees with task.wait is reported", function()
  -- a world whose clock runs 3x faster than task.wait
  local d = H.boot({ pre = function(x)
    x.g:spawn(x.me)
    x.env.os_clock = function() return x.sim.t * 3 end
  end })
  T.ok(d.inst, tostring(d.err))
  H.run(d, 3)
  T.ok(d.inst.host.clock_suspect, "mismatch should be flagged")
  T.contains(d.inst.report(), "CLOCK WARNING")
end)

T.test("clock self-check: a sane clock is not flagged", function()
  local c = H.standard()
  H.run(c, 5)
  T.falsy(c.inst.host.clock_suspect)
  T.falsy(string.find(c.inst.report(), "CLOCK WARNING", 1, true))
end)

return true
