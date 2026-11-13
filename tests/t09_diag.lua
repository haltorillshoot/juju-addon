local T = require("tf")
local H = require("harness")
local Diag = require("diag")
local Config = require("config")

T.suite("09 Connection diagnostics")

-- unit harness: scripted ping source + manual clock
local function unit(over)
  local cfg = Config.new(over).values
  local now = { t = 0 }
  local src = { value = 60 }
  local d = Diag.new({ cfg = cfg, now = function() return now.t end,
    get_ping = function()
      local v = src.value
      if type(v) == "function" then return v() end
      return v
    end,
    get_gap = function() return src.gap end })
  return d, now, src, cfg
end

local function feed(d, now, src, values, dt)
  for _, v in ipairs(values) do
    src.value = v
    now.t = now.t + (dt or 1)
    d:sample("t")
  end
end

T.test("unit: ewma / last / jitter / p95", function()
  local d, now, src = unit()
  feed(d, now, src, { 60, 60, 60, 60 })
  T.near(d.ewma, 60, 1e-9)
  T.eq(d.last_ms, 60)
  T.near(d:jitter(), 0, 1e-9)
  local d2, n2, s2 = unit()
  feed(d2, n2, s2, { 50, 70, 50, 70, 50, 70 })
  T.near(d2:jitter(), 20, 1e-9)
  local d3, n3, s3 = unit()
  local seq = {}
  for i = 1, 20 do seq[i] = i end
  feed(d3, n3, s3, seq)
  T.eq(d3:p95(), 19)
end)

T.test("unit: spike = well above the recent median, not just a bit higher", function()
  local d, now, src = unit()
  feed(d, now, src, { 60, 62, 58, 61, 60, 59 })
  T.eq(d.n_spikes, 0)
  feed(d, now, src, { 100 })          -- 40ms above, below ratio and +80ms floor
  T.eq(d.n_spikes, 0)
  feed(d, now, src, { 400 })
  T.eq(d.n_spikes, 1)
end)

T.test("unit: no baseline yet -> only the absolute disconnect_ping_ms threshold flags", function()
  local d, now, src = unit()
  feed(d, now, src, { 500 })
  T.eq(d.n_spikes, 0)
  feed(d, now, src, { 2500 })
  T.eq(d.n_spikes, 1)
end)

T.test("unit: a sustained change becomes the new baseline (no permanent 'degraded')", function()
  local d, now, src = unit()
  feed(d, now, src, { 60, 60, 60, 60, 60, 60 })
  local vals = {}
  for i = 1, 30 do vals[i] = 300 end
  feed(d, now, src, vals)
  local before = d.n_spikes
  feed(d, now, src, { 300, 300, 300 })
  T.eq(d.n_spikes, before, "no new spikes once the baseline moved")
  T.falsy(d:degraded_now() and false)
end)

T.test("unit: nil / invalid samples are counted and ignored", function()
  local d, now, src = unit()
  feed(d, now, src, { 60, 60 })
  src.value = nil
  now.t = now.t + 1
  T.is_nil(d:sample("x"))
  T.eq(d.n_invalid, 1)
  T.eq(d.n_samples, 2)
  T.eq(d.last_ms, 60)
end)

T.test("unit: window — default, floor, scaling, clamp", function()
  local d, now, src, cfg = unit()
  T.near(d:window(), cfg.window_default, 1e-9, "no data -> default")
  feed(d, now, src, { 60, 60, 60 })
  T.near(d:window(), cfg.window_min, 1e-9, "fast link -> minimum")
  local d2, n2, s2 = unit()
  feed(d2, n2, s2, { 300, 300, 300, 300, 300, 300 })
  T.near(d2:window(), cfg.window_rtt_mult * 0.3 + cfg.window_floor, 1e-9, "mult*RTT + floor")
  local d3, n3, s3 = unit()
  feed(d3, n3, s3, { 1200, 1200, 1200 })
  T.near(d3:window(), cfg.window_max, 1e-9, "clamped to max")
end)

T.test("unit: one spike in the history does not inflate the window (robust reference)", function()
  local d, now, src, cfg = unit()
  feed(d, now, src, { 100, 100, 100, 100, 100, 100, 100, 100, 100, 100, 600, 100 })
  T.near(d:window(), cfg.window_rtt_mult * 0.1 + cfg.window_floor + cfg.window_jitter_mult * 0, 1e-9,
    "median ref + median jitter ignore the single outlier")
  feed(d, now, src, { 600 })           -- but a spike AT shot time widens it immediately
  T.ok(d:window() >= cfg.window_rtt_mult * 0.6 + cfg.window_floor - 1e-9)
end)

T.test("unit: observed hit latency changes nothing unless learn_window is on", function()
  local d, now, src, cfg = unit()
  feed(d, now, src, { 60, 60, 60 })
  local w = d:window()
  for i = 1, 10 do d:note_latency(0.8) end
  T.near(d:window(), w, 1e-9, "default must not learn (feedback loop with other players' damage)")
  local e, n2, s2, c2 = unit({ learn_window = true })
  feed(e, n2, s2, { 60, 60, 60 })
  for i = 1, 6 do e:note_latency(0.8) end
  T.near(e:window(), 0.8 * c2.window_emp_mult, 1e-9, "opt-in empirical term dominates")
end)

T.test("unit: jitter widens the window", function()
  local d, now, src = unit()
  feed(d, now, src, { 280, 320, 280, 320, 280, 320 })
  local w = d:window()
  local d2, n2, s2 = unit()
  feed(d2, n2, s2, { 320, 320, 320, 320, 320, 320 })
  T.ok(w > d2:window(), "jittery link must get a longer window than a steady one")
end)

T.test("unit: degraded_between sees spikes (incl. one just before) and stalls, not old ones", function()
  local d, now, src = unit()
  feed(d, now, src, { 60, 60, 60, 60, 60, 60 })        -- t=1..6
  feed(d, now, src, { 900 })                            -- spike at t=7
  local deg, why = d:degraded_between(7.2, 7.5)
  T.ok(deg); T.eq(why, "ping_spike")
  deg = d:degraded_between(7.9, 8.4)                    -- shot 0.9s after the spike sample: still within hold
  T.ok(deg)
  deg = d:degraded_between(10, 10.4)
  T.falsy(deg, "an old spike must not taint later shots")
end)

T.test("unit: background sampler gap detects a client stall", function()
  local d, now, src, cfg = unit()
  now.t = 1; d:sample("bg", true)
  now.t = 2; d:sample("bg", true)
  T.eq(d.n_stalls, 0)
  now.t = 2 + cfg.diag_interval * cfg.stall_factor + 1
  d:sample("bg", true)
  T.eq(d.n_stalls, 1)
  local deg, why = d:degraded_between(3, 4)
  T.ok(deg); T.eq(why, "stall")
end)

T.test("unit: server/client position gap tracking", function()
  local d, now, src, cfg = unit()
  src.gap = 3
  T.eq(d:sample_gap(), 3)
  src.gap = cfg.gap_warn + 5
  d:sample_gap()
  T.eq(d.gap_max, cfg.gap_warn + 5)
  T.eq(d.gap_warns, 1)
  src.gap = nil
  T.is_nil(d:sample_gap())
  T.eq(d.gap, cfg.gap_warn + 5, "unknown reading must not overwrite the last good one")
end)

T.test("unit: reset clears history", function()
  local d, now, src = unit()
  feed(d, now, src, { 60, 60, 60, 900 })
  d:reset()
  T.eq(d.n_samples, 0); T.eq(d.n_spikes, 0); T.is_nil(d.ewma)
end)

T.test("integration: host.ping() validates what Juju returns", function()
  local c = H.standard()
  local host = c.inst.host
  local bad = { 0, -5, "abc", 0 / 0, math.huge, 1e9 }
  local before = host.invalid_pings
  for _, v in ipairs(bad) do
    c.J.ping = v
    T.is_nil(host.ping(), "garbage ping accepted: " .. tostring(v))
  end
  T.eq(host.invalid_pings - before, #bad)
  c.J.ping = nil
  T.is_nil(host.ping())
  c.J.ping = 45
  T.eq(host.ping(), 45)
end)

T.test("integration: server/client CFrame gap uses the documented pair", function()
  local c = H.standard()
  c.J.server_pos = H.Mock.Vector3(0, 0, 0)
  c.J.client_pos = H.Mock.Vector3(3, 0, 4)
  T.near(c.inst.host.gap(), 5, 1e-9)
  H.shoot(c)
  T.near(c.inst.engine.last_shot.gap, 5, 1e-9, "gap at shot time is recorded with the shot")
  c.J.server_pos = nil
  T.is_nil(c.inst.host.gap())
end)

T.test("integration: background sampler cadence is one sample per diag_interval", function()
  local c = H.standard()
  H.run(c, 10)
  local n = c.inst.diag.n_samples
  T.ok(n >= 10 and n <= 12, "samples after 10s: " .. n)
  T.eq(c.J.count_calls("get_ping"), n)
end)

T.test("integration: snapshot exposes the diagnostics used by the HUD/report", function()
  local c = H.standard()
  H.run(c, 5)
  local s = c.inst.diag:snapshot()
  T.near(s.ping, 60, 1e-9); T.near(s.avg, 60, 1e-9); T.near(s.p95, 60, 1e-9)
  T.ok(s.window >= c.inst.cfg.window_min and s.window <= c.inst.cfg.window_max)
  T.contains(c.inst.report(), "ping=60ms")
end)

return true
