-- diag.lua
-- Connection diagnostics built ONLY from what the documented API exposes:
--   juju.get_ping() (ms), and the server/client CFrame position gap.
-- Derived values (jitter, spikes, stalls, adaptive window) are computed here; nothing else
-- about the network (packet loss, server tick, ...) is observable and none is claimed.

local U = require("util")

local D = {}
D.__index = D

function D.new(deps)
  local cfg = deps.cfg
  local self = setmetatable({}, D)
  self.cfg = cfg
  self.now = deps.now
  self.get_ping = deps.get_ping or function() return nil end
  self.get_gap = deps.get_gap or function() return nil end
  self.log = deps.log or function() end
  self.samples = U.Ring.new(cfg.diag_samples)
  self.spikes = U.Ring.new(32)      -- timestamps of spike samples
  self.stalls = U.Ring.new(16)      -- {t0, t1} client stalls seen by the background sampler
  self.lat = U.Ring.new(32)         -- observed shot->damage latencies (s)
  self.ewma = nil
  self.last_ms = nil
  self.last_bg = nil
  self.n_samples, self.n_invalid, self.n_spikes, self.n_stalls = 0, 0, 0, 0
  self.gap, self.gap_max, self.gap_warns = nil, 0, 0
  return self
end

-- Median of the most recent samples; nil until there are 5.
function D:_baseline()
  local n = self.samples:size()
  if n < 5 then return nil end
  local from = n - 15
  if from < 1 then from = 1 end
  local arr = {}
  for i = from, n do arr[#arr + 1] = self.samples:get(i).ms end
  return U.median(arr)
end

-- Take one ping sample. `background` marks the periodic sampler, which also detects client stalls
-- (a gap between two background samples much longer than the interval).
function D:sample(tag, background)
  local cfg = self.cfg
  local t = self.now()
  if background then
    if self.last_bg and (t - self.last_bg) > cfg.diag_interval * cfg.stall_factor then
      self.stalls:push({ t0 = self.last_bg, t1 = t })
      self.n_stalls = self.n_stalls + 1
      self.log("warn", string.format("client stall: %.0f ms between background samples",
        (t - self.last_bg) * 1000))
    end
    self.last_bg = t
  end
  local ms = self.get_ping()
  if ms == nil then
    self.n_invalid = self.n_invalid + 1
    return nil
  end
  local base = self:_baseline()
  local spike = ms >= cfg.disconnect_ping_ms
  if not spike and base then
    spike = ms > math.max(base * cfg.spike_ratio, base + cfg.spike_min_ms)
  end
  if spike then
    self.spikes:push(t)
    self.n_spikes = self.n_spikes + 1
    self.log("warn", string.format("ping spike %.0f ms (baseline %s) [%s]", ms,
      base and string.format("%.0f", base) or "n/a", tostring(tag)))
  end
  self.samples:push({ t = t, ms = ms, spike = spike })
  self.n_samples = self.n_samples + 1
  self.last_ms = ms
  if self.ewma == nil then
    self.ewma = ms
  else
    self.ewma = self.ewma + cfg.ewma_alpha * (ms - self.ewma)
  end
  return ms
end

function D:sample_gap()
  local g = self.get_gap()
  if g == nil then return nil end
  self.gap = g
  if g > self.gap_max then self.gap_max = g end
  if g > self.cfg.gap_warn then self.gap_warns = self.gap_warns + 1 end
  return g
end

-- Jitter (ms): MEDIAN absolute difference between consecutive recent samples. The median keeps a
-- rare spike (which is flagged separately) from inflating the confirmation window.
function D:jitter()
  local n = self.samples:size()
  if n < 2 then return 0 end
  local from = n - 15
  if from < 1 then from = 1 end
  local diffs = {}
  local prev = self.samples:get(from).ms
  for i = from + 1, n do
    local cur = self.samples:get(i).ms
    diffs[#diffs + 1] = math.abs(cur - prev)
    prev = cur
  end
  return U.median(diffs) or 0
end

function D:p95()
  local n = self.samples:size()
  if n == 0 then return nil end
  local arr = {}
  for i = 1, n do arr[i] = self.samples:get(i).ms end
  return U.percentile(arr, 95)
end

-- Record the delay between a shot and the damage it produced (hit or late hit), so the window
-- follows what the game actually does, not only what the ping suggests.
function D:note_latency(sec)
  if U.is_finite(sec) and sec > 0 then self.lat:push(sec) end
end

-- Confirmation window in seconds, derived from measured ping and jitter:
--   window = rtt_mult * RTT_ref + jitter_mult * jitter + floor      (clamped to [min, max])
-- RTT_ref = max(median of recent samples, latest sample): robust against a single spike, yet a
-- rising ping widens the window immediately through the latest sample. The optional learn_window
-- term (default OFF) lifts it to emp_mult * p95(observed hit latency).
function D:window()
  local cfg = self.cfg
  local model = 0
  if self.samples:size() > 0 then
    local ref = math.max(self:_baseline() or self.ewma or 0, self.last_ms or 0)
    model = cfg.window_rtt_mult * ref / 1000 + cfg.window_jitter_mult * self:jitter() / 1000
      + cfg.window_floor
  end
  local emp = 0
  if cfg.learn_window and self.lat:size() >= cfg.window_emp_min then
    emp = (U.percentile(self.lat:to_array(), 95) or 0) * cfg.window_emp_mult
  end
  local w = math.max(model, emp)
  if w <= 0 then w = cfg.window_default end
  return U.clamp(w, cfg.window_min, cfg.window_max)
end

-- true + reason if a spike or client stall overlaps [t0, t1] (a spike seen just before t0 counts:
-- it describes the connection state at the moment of the shot).
function D:degraded_between(t0, t1)
  local hold = self.cfg.diag_interval
  for i = self.spikes:size(), 1, -1 do
    local ts = self.spikes:get(i)
    if ts < t0 - hold then break end
    if ts <= t1 then return true, "ping_spike" end
  end
  for i = self.stalls:size(), 1, -1 do
    local s = self.stalls:get(i)
    if s.t1 < t0 then break end
    if s.t0 <= t1 then return true, "stall" end
  end
  return false
end

-- true when a spike/stall happened within the last two sampling intervals.
function D:degraded_now()
  local t = self.now()
  local hold = self.cfg.diag_interval * 2
  local lastspike = self.spikes:last()
  if lastspike and t - lastspike <= hold then return true end
  local st = self.stalls:last()
  if st and t - st.t1 <= hold then return true end
  return false
end

function D:snapshot()
  return {
    ping = self.last_ms, avg = self.ewma, p95 = self:p95(), jitter = self:jitter(),
    samples = self.n_samples, invalid = self.n_invalid, spikes = self.n_spikes,
    stalls = self.n_stalls, gap = self.gap, gap_max = self.gap_max, gap_warns = self.gap_warns,
    window = self:window(), degraded = self:degraded_now(), lat_n = self.lat:size(),
  }
end

function D:reset()
  self.samples:clear(); self.spikes:clear(); self.stalls:clear(); self.lat:clear()
  self.ewma, self.last_ms, self.last_bg = nil, nil, nil
  self.n_samples, self.n_invalid, self.n_spikes, self.n_stalls = 0, 0, 0, 0
  self.gap, self.gap_max, self.gap_warns = nil, 0, 0
end

return D
