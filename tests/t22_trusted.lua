-- The confirmation window follows TRUSTED latencies (hits Juju attributed to the local bullet).
-- Driven by a live finding: the confirmation arrived ~2.9 x ping after the shot, far beyond
-- window_rtt_mult * RTT, so shots were expiring before their own confirmation could arrive.
local T = require("tf")
local H = require("harness")
local Diag = require("diag")
local Config = require("config")

T.suite("22 Window follows confirmed latency")

local function unit(over)
  local cfg = Config.new(over).values
  local now = { t = 0 }
  local src = { value = 60 }
  local d = Diag.new({ cfg = cfg, now = function() return now.t end,
    get_ping = function() return src.value end })
  for i = 1, 6 do
    now.t = now.t + 1
    d:sample("t")
  end
  return d, cfg
end

T.test("unit: trusted latencies widen the window without learn_window", function()
  local d, cfg = unit()
  T.near(d:window(), cfg.window_min, 1e-9)
  for i = 1, cfg.window_emp_min do d:note_latency(0.5, true) end
  T.near(d:window(), 0.5 * cfg.window_emp_mult, 1e-9)
end)

T.test("unit: untrusted latencies still do nothing by default", function()
  local d, cfg = unit()
  for i = 1, 20 do d:note_latency(0.9, false) end
  T.near(d:window(), cfg.window_min, 1e-9)
  T.is_nil(d:trusted_latency())
end)

T.test("unit: trusted term needs window_emp_min samples and respects the clamp", function()
  local d, cfg = unit()
  for i = 1, cfg.window_emp_min - 1 do d:note_latency(0.5, true) end
  T.near(d:window(), cfg.window_min, 1e-9, "not enough trusted samples yet")
  d:note_latency(0.5, true)
  T.ok(d:window() > cfg.window_min)
  local e = unit()
  for i = 1, 10 do e:note_latency(9.0, true) end
  T.near(e:window(), cfg.window_max, 1e-9, "still clamped to window_max")
end)

T.test("unit: reset clears trusted latencies", function()
  local d, cfg = unit()
  for i = 1, 10 do d:note_latency(0.5, true) end
  d:reset()
  T.is_nil(d:trusted_latency())
  T.near(d:window(), cfg.window_default, 1e-9)
end)

-- integration -----------------------------------------------------------------------------
local function confirm(c, enemy, delay, dmg)
  c.sim.task.delay(delay, function()
    c.J.signals.on_local_bullet_confirmed:Fire(enemy, { Name = "HumanoidRootPart" }, tostring(dmg or -15))
  end)
end

-- latencies actually measured live (min 112ms, avg 156ms, max 226ms at 52ms ping)
local LIVE_LAT = { 0.112, 0.134, 0.151, 0.168, 0.182, 0.199, 0.212, 0.226 }

T.test("live pattern: confirmations at ~2.9x ping teach the window, later shots stop being missed", function()
  local c = H.standard({ ping = 52 })
  H.run(c, 3)
  local w0 = c.inst.diag:window()
  T.near(w0, c.inst.cfg.window_min, 1e-9, "starts at the floor for a 52ms link")

  -- the first confirmations arrive inside deadline + grace, so they still land as hits
  for _, lat in ipairs(LIVE_LAT) do
    H.shoot(c)
    confirm(c, c.enemies[1], lat)
    H.run(c, 1.5)
  end
  local w1 = c.inst.diag:window()
  T.ok(w1 > w0, "window did not learn from confirmed hits: " .. w1 .. " vs " .. w0)
  T.ok(w1 >= 0.226, "window should cover the slowest observed confirmation, got " .. w1)
  T.eq(H.stats(c).hits, #LIVE_LAT)

  -- a confirmation at 226ms (seen live) now lands inside the window itself
  H.shoot(c)
  confirm(c, c.enemies[1], 0.226)
  H.settle(c)
  local shot = c.inst.engine.last_shot
  T.eq(shot.outcome, "hit")
  T.ok(shot.window >= 0.226, "the shot's own window must cover it, got " .. shot.window)
  H.check_invariant(c, T)
end)

T.test("health-inferred hits alone do NOT widen the window (no feedback loop)", function()
  local c = H.standard({ ping = 52 })
  H.run(c, 3)
  local w0 = c.inst.diag:window()
  for _, lat in ipairs(LIVE_LAT) do
    H.shoot(c)
    H.damage_after(c, c.enemies[1], lat, 10)       -- could be anybody's damage
    H.run(c, 1.5)
  end
  T.near(c.inst.diag:window(), w0, 1e-9, "unconfirmed hits must not steer the window")
  -- the honest consequence, and exactly why the Juju signal matters: without confirmation the
  -- window stays at the floor, so the slowest real hits (212ms, 226ms) fall outside it and are
  -- reported as unconfirmed-late instead of hits
  local st = H.stats(c)
  T.eq(st.hits, 6)
  T.eq(st.unconfirmed, 2)
  T.eq(c.inst.engine.reasons.late_damage, 2)
  T.eq(st.misses, 0, "a late hit is never called a miss")
  H.check_invariant(c, T)
end)

T.test("a corroborated hit (health first, Juju after) also teaches the window", function()
  local c = H.standard({ ping = 52 })
  H.run(c, 3)
  local w0 = c.inst.diag:window()
  for _, lat in ipairs(LIVE_LAT) do
    H.shoot(c)
    H.damage_after(c, c.enemies[1], lat, 10)
    confirm(c, c.enemies[1], lat + 0.07)           -- live order: confirmation ~70ms after the damage
    H.run(c, 1.5)
  end
  T.eq(H.stats(c).confirmed_hits, #LIVE_LAT)
  T.ok(c.inst.diag:trusted_latency() ~= nil, "corroboration must feed the trusted ring")
  T.ok(c.inst.diag:window() > w0, "window did not learn from corroborated hits")
end)

T.test("the report names the trusted sample count and p95", function()
  local c = H.standard({ ping = 52 })
  for _, lat in ipairs(LIVE_LAT) do
    H.shoot(c)
    confirm(c, c.enemies[1], lat)
    H.run(c, 1.5)
  end
  local r = c.inst.report()
  T.contains(r, "trusted=8")
  T.contains(r, "window follows this")
end)

return true
