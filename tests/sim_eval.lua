-- tests/sim_eval.lua
-- SIMULATED reliability study of the confirmation-window strategy under different latency
-- conditions. It drives the real Engine + Diag modules with a stochastic network model and
-- compares the outcome the addon reports against GROUND TRUTH that only the simulation knows.
--
-- Network model (all assumptions, clearly NOT measurements of Hood Customs):
--   * each shot has a true hit probability 0.5; if it hits, damage reaches the client
--     (true_rtt + 25ms server processing) later, as a 3-event pellet burst
--   * true_rtt ~ base * (1 +/- jitter), with occasional spikes (x spike_mult)
--   * juju.get_ping() reports true_rtt * (1 +/- ping_noise): "clean" = exact, "noisy" = +/-30%
--   * other players' damage hits the same target as a Poisson process (bg_rate per second):
--     this is what creates false-hit risk for long windows
-- Ground truth: a shot is a "true hit" iff the simulation scheduled damage for it.

local Mock = require("mock")
local Config = require("config")
local Diag = require("diag")
local Engine = require("engine")

local S = {}

local function lcg(seed)
  local s = seed % 2147483647
  if s <= 0 then s = s + 2147483646 end
  return function()
    s = (s * 48271) % 2147483647
    return s / 2147483647
  end
end

-- Strategy "B" is the shipped default (empty override). Keep it first among the adaptive ones.
S.strategies = {
  { name = "fixed 250ms", cfg = { window_min = 0.25, window_max = 0.25, window_default = 0.25 } },
  { name = "fixed 600ms", cfg = { window_min = 0.6, window_max = 0.6, window_default = 0.6 } },
  { name = "fixed 1500ms", cfg = { window_min = 1.5, window_max = 1.5, window_default = 1.5 } },
  { name = "A learn_window=on", cfg = { learn_window = true } },
  { name = "B shipped default", cfg = {} },
  { name = "C old x2.0 +100 min250", cfg = { window_rtt_mult = 2.0, window_floor = 0.10, window_min = 0.25 } },
  { name = "D tight x1.25 min120", cfg = { window_rtt_mult = 1.25, window_floor = 0.05, window_min = 0.12 } },
  { name = "E causal ratio .8", cfg = { causal_ratio = 0.8 } },
  { name = "F causal floor off", cfg = { causal_check = false } },
  { name = "G no late grace", cfg = { late_grace = 0 } },
  { name = "H late grace x4", cfg = { late_grace = 4 } },
}

local BASE = {
  { name = "40ms steady", base_ms = 40, jitter = 0.15, spike_p = 0.0, spike_mult = 1, bg_rate = 0.3 },
  { name = "90ms normal", base_ms = 90, jitter = 0.25, spike_p = 0.02, spike_mult = 3, bg_rate = 0.3 },
  { name = "160ms lagged", base_ms = 160, jitter = 0.30, spike_p = 0.03, spike_mult = 3, bg_rate = 0.3 },
  { name = "260ms poor", base_ms = 260, jitter = 0.30, spike_p = 0.05, spike_mult = 3, bg_rate = 0.3 },
  { name = "400ms bad", base_ms = 400, jitter = 0.40, spike_p = 0.05, spike_mult = 2.5, bg_rate = 0.3 },
  { name = "700ms awful", base_ms = 700, jitter = 0.40, spike_p = 0.05, spike_mult = 2, bg_rate = 0.3 },
}

local function with(extra)
  local out = {}
  for i, sc in ipairs(BASE) do
    local c = {}
    for k, v in pairs(sc) do c[k] = v end
    for k, v in pairs(extra) do c[k] = v end
    out[i] = c
  end
  return out
end

S.clean = with({ ping_noise = 0 })
S.noisy = with({ ping_noise = 0.3 })
S.quiet = with({ ping_noise = 0, bg_rate = 0 })      -- nobody else deals damage

local WEAPON = { key = "doublebarrelsg", name = "[Double-Barrel SG]", is_dbs = true }

-- one run; returns tally table
function S.run(strategy, scenario, seed, shots)
  shots = shots or 300
  local sim = Mock.Sim.new()
  local cfg = Config.new(strategy.cfg).values
  local rng = lcg(seed)
  local true_rtt, reading = scenario.base_ms, scenario.base_ms
  local function redraw()
    local r = scenario.base_ms * (1 + scenario.jitter * (rng() * 2 - 1))
    if rng() < scenario.spike_p then r = r * scenario.spike_mult end
    true_rtt = r
    reading = r * (1 + (scenario.ping_noise or 0) * (rng() * 2 - 1))
  end
  local diag = Diag.new({ cfg = cfg, now = sim.clock, get_ping = function() return reading end })
  local eng = Engine.new({ cfg = cfg, now = sim.clock, diag = diag,
    timers = { delay = sim.task.delay, cancel = sim.task.cancel } })

  local function bg()
    redraw()
    diag:sample("bg", true)
    sim.task.delay(1, bg)
  end
  redraw()
  diag:sample("init")
  sim.task.delay(1, bg)
  sim:advance(8)                                   -- warm-up so a baseline exists

  local interval = 2.0
  local recs = {}
  for i = 1, shots do
    redraw()
    local ping = diag:sample("shot")
    local true_hit = rng() < 0.5
    local shot = eng:register_shot({ weapon = WEAPON, candidates = { [1] = true }, ncand = 1, ping_ms = ping })
    recs[#recs + 1] = { shot = shot, truth = true_hit }
    if true_hit then
      local arrive = (true_rtt + 25) / 1000
      for k = 0, 2 do
        sim.task.delay(arrive + k * 0.002, function() eng:register_damage({ uid = 1, amount = 10 }) end)
      end
    end
    if scenario.bg_rate > 0 then
      local tt = 0
      while true do
        tt = tt - math.log(1 - rng()) / scenario.bg_rate
        if tt > interval then break end
        sim.task.delay(tt, function() eng:register_damage({ uid = 1, amount = 7 }) end)
      end
    end
    sim:advance(interval)
  end
  sim:advance(6)

  local r = { n = #recs, true_hits = 0, hit_ok = 0, false_hit = 0, miss_ok = 0, false_miss = 0,
    unc_hit = 0, unc_miss = 0, other = 0, window_sum = 0 }
  for _, x in ipairs(recs) do
    local o = x.shot.outcome
    r.window_sum = r.window_sum + x.shot.window
    if x.truth then r.true_hits = r.true_hits + 1 end
    if o == "hit" then
      if x.truth then r.hit_ok = r.hit_ok + 1 else r.false_hit = r.false_hit + 1 end
    elseif o == "miss" then
      if x.truth then r.false_miss = r.false_miss + 1 else r.miss_ok = r.miss_ok + 1 end
    elseif o == "unconfirmed" then
      if x.truth then r.unc_hit = r.unc_hit + 1 else r.unc_miss = r.unc_miss + 1 end
    else
      r.other = r.other + 1
    end
  end
  return r
end

local function add(a, b)
  for k, v in pairs(b) do a[k] = (a[k] or 0) + v end
end

-- results[strategy_index][scenario_index] = tally summed over seeds
function S.run_all(opts)
  opts = opts or {}
  local seeds = opts.seeds or { 11, 23, 37 }
  local shots = opts.shots or 200
  local scenarios = opts.scenarios or S.clean
  local out = {}
  for si, st in ipairs(S.strategies) do
    out[si] = {}
    for ci, sc in ipairs(scenarios) do
      local tot = {}
      for _, seed in ipairs(seeds) do add(tot, S.run(st, sc, seed, shots)) end
      out[si][ci] = tot
    end
  end
  return out, scenarios
end

function S.pct(a, b) if b == 0 then return 0 end return a / b * 100 end

function S.format(results, scenarios, title)
  local L = {}
  local function row(fmt, ...) L[#L + 1] = string.format(fmt, ...) end
  local metrics = {
    { "RECALL: true hits reported as HIT (%)", function(t) return S.pct(t.hit_ok, t.true_hits) end, "%.1f" },
    { "FALSE HITS: hit reported, shot did not hit (% of the shots that did NOT hit)",
      function(t) return S.pct(t.false_hit, t.n - t.true_hits) end, "%.1f" },
    { "FALSE MISSES: miss reported, shot did hit (count, after late-damage re-classification)",
      function(t) return t.false_miss end, "%d" },
    { "UNCONFIRMED of all shots (%)", function(t) return S.pct(t.unc_hit + t.unc_miss, t.n) end, "%.1f" },
    { "mean confirmation window (ms)", function(t) return t.window_sum / t.n * 1000 end, "%.0f" },
  }
  row("## %s", title or "")
  for _, m in ipairs(metrics) do
    row("")
    row("%s", m[1])
    local head = string.format("  %-22s", "strategy \\ scenario")
    for _, sc in ipairs(scenarios) do head = head .. string.format(" %13s", sc.name) end
    L[#L + 1] = head
    for si, st in ipairs(S.strategies) do
      local line = string.format("  %-22s", st.name)
      for ci = 1, #scenarios do
        line = line .. string.format(" %13s", string.format(m[3], m[2](results[si][ci])))
      end
      L[#L + 1] = line
    end
  end
  return table.concat(L, "\n")
end

return S
