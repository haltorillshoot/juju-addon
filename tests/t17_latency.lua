local T = require("tf")
local S = require("sim_eval")

T.suite("17 Reliability under latency (SIMULATED)")

local cache = {}
local function data(name, scenarios, shots)
  if not cache[name] then
    local res, sc = S.run_all({ scenarios = scenarios, shots = shots or 200 })
    cache[name] = { res = res, sc = sc }
  end
  return cache[name].res, cache[name].sc
end

local function idx(name)
  for i, s in ipairs(S.strategies) do if s.name == name then return i end end
  error("no strategy " .. name)
end
local B = "B shipped default"

local function total(res, si, field, upto)
  local n = 0
  for ci = 1, (upto or #res[si]) do n = n + res[si][ci][field] end
  return n
end

T.test("strategy B really is the shipped default (empty override)", function()
  T.eq(next(S.strategies[idx(B)].cfg), nil)
end)

T.test("with NO other damage source, no strategy ever reports a false hit", function()
  local res = data("quiet", S.quiet, 120)
  for si, st in ipairs(S.strategies) do
    for ci, sc in ipairs(S.quiet) do
      T.eq(res[si][ci].false_hit, 0, st.name .. " @ " .. sc.name)
    end
  end
end)

T.test("default recall: >=98% up to 400ms, >=90% at 700ms (clean and noisy ping)", function()
  for _, name in ipairs({ "clean", "noisy" }) do
    local res, sc = data(name, S[name])
    local b = idx(B)
    for ci = 1, #sc do
      local r = S.pct(res[b][ci].hit_ok, res[b][ci].true_hits)
      local need = (ci <= 5) and 98 or 90
      T.ok(r >= need, string.format("%s recall %.1f%% @ %s", name, r, sc[ci].name))
    end
  end
end)

T.test("default beats the short fixed windows on recall where latency is high", function()
  local res, sc = data("clean", S.clean)
  local b, f = idx(B), idx("fixed 250ms")
  for ci = 4, #sc do
    local rb = S.pct(res[b][ci].hit_ok, res[b][ci].true_hits)
    local rf = S.pct(res[f][ci].hit_ok, res[f][ci].true_hits)
    T.ok(rb > rf + 20, string.format("@ %s default %.1f%% vs fixed250 %.1f%%", sc[ci].name, rb, rf))
  end
end)

T.test("default has far fewer false hits than the long fixed window", function()
  local res = data("clean", S.clean)
  local b, f = idx(B), idx("fixed 1500ms")
  local fb, ff = total(res, b, "false_hit"), total(res, f, "false_hit")
  T.ok(fb < ff * 0.6, string.format("false hits default %d vs fixed1500 %d", fb, ff))
end)

T.test("the tuned defaults beat the first-draft defaults (C) on false hits, same recall", function()
  for _, name in ipairs({ "clean", "noisy" }) do
    local res = data(name, S[name])
    local b, c = idx(B), idx("C old x2.0 +100 min250")
    T.ok(total(res, b, "false_hit") < total(res, c, "false_hit"),
      string.format("%s: default %d vs old %d", name, total(res, b, "false_hit"), total(res, c, "false_hit")))
    T.ok(total(res, b, "hit_ok") >= total(res, c, "hit_ok") - 3, name .. ": recall must not drop")
  end
end)

T.test("learn_window=on (A) is worse than the default: longer windows, more false hits", function()
  local res, sc = data("clean", S.clean)
  local a, b = idx("A learn_window=on"), idx(B)
  T.ok(total(res, a, "false_hit") > total(res, b, "false_hit"))
  local wa, wb = total(res, a, "window_sum", 4), total(res, b, "window_sum", 4)
  T.ok(wa > wb * 1.3, string.format("mean window sums A %.0f vs B %.0f", wa, wb))
end)

T.test("late-damage re-classification: no false misses up to 400ms, and far fewer than fixed short windows", function()
  local res = data("clean", S.clean)
  local b = idx(B)
  T.eq(total(res, b, "false_miss", 5), 0, "default false misses up to 400ms")
  for _, name in ipairs({ "fixed 250ms", "fixed 600ms" }) do
    T.ok(total(res, idx(name), "false_miss") > total(res, b, "false_miss"), name)
  end
end)

T.test("the relative late grace keeps 'unconfirmed' low (an absolute 4x grace over-reclassifies)", function()
  local res, sc = data("clean", S.clean)
  local b, h = idx(B), idx("H late grace x4")
  for ci = 1, #sc do
    local ub = res[b][ci].unc_hit + res[b][ci].unc_miss
    local uh = res[h][ci].unc_hit + res[h][ci].unc_miss
    T.ok(ub < uh, string.format("@ %s unconfirmed default %d vs x4 %d", sc[ci].name, ub, uh))
  end
end)

T.test("the causal floor lowers false hits (vs floor off) at no cost in recall", function()
  for _, name in ipairs({ "clean", "noisy" }) do
    local res = data(name, S[name])
    local b, f = idx(B), idx("F causal floor off")
    T.ok(total(res, b, "false_hit") < total(res, f, "false_hit"), name)
    T.ok(total(res, b, "hit_ok") >= total(res, f, "hit_ok") - 2, name)
  end
end)

T.test("every simulated shot ends in exactly one outcome", function()
  local res = data("clean", S.clean)
  for si = 1, #S.strategies do
    for ci = 1, #S.clean do
      local t = res[si][ci]
      T.eq(t.hit_ok + t.false_hit + t.miss_ok + t.false_miss + t.unc_hit + t.unc_miss + t.other, t.n)
      T.eq(t.other, 0, "no pending/not_fired expected in this model")
    end
  end
end)

T.test("print the study (also written to docs/SIM_RESULTS.md)", function()
  local rc, sc = data("clean", S.clean)
  local rn = data("noisy", S.noisy)
  local clean_txt = S.format(rc, sc, "Clean ping readings (get_ping == true RTT)")
  local noisy_txt = S.format(rn, S.noisy, "Noisy ping readings (get_ping off by up to +/-30%)")
  print("")
  print("---- SIMULATED latency study: 3 seeds x 200 shots per cell, true hit rate 50% ----")
  print(clean_txt)
  print("")
  print(noisy_txt)
  local root = ROOT or "."
  local f = io.open(root .. "/docs/SIM_RESULTS.md", "w")
  if f then
    f:write("# Simulated latency study\n\n")
    f:write("**SIMULATION ONLY.** The real `Engine` and `Diag` modules were driven by a synthetic network model ")
    f:write("(every assumption is in the header of `tests/sim_eval.lua`). Ground truth exists only inside the ")
    f:write("simulation, so these numbers show how the classification logic behaves under the stated model. ")
    f:write("They are NOT measurements of Hood Customs or of any real connection.\n\n")
    f:write("Per cell: 3 seeds x 200 shots, true hit probability 50%, *other players'* damage on the same target ")
    f:write("at 0.3 events/s, server processing 25ms, jitter/spikes as named in the scenario.\n\n")
    f:write("Strategy B is the shipped default. Findings that drove the defaults:\n\n")
    f:write("* Fixed short windows lose hits on laggy links (recall collapses at 260ms+).\n")
    f:write("* Long windows (fixed 1500ms) keep recall but admit ~3x more unrelated damage as false hits. ")
    f:write("False hits are inherent to *any* window: another player's damage on the same target looks identical. ")
    f:write("Narrower windows lower them, which is why the window follows measured ping.\n")
    f:write("* A window that *learns* from observed hit latency (A) feeds on other players' damage and drifts long ")
    f:write("(feedback loop) -> disabled by default.\n")
    f:write("* Late-damage re-classification with an absolute/long grace (H) relabels many correct misses as ")
    f:write("unconfirmed; a grace relative to the window (B, 0.5x) keeps them.\n\n")
    f:write("```\n" .. clean_txt .. "\n\n" .. noisy_txt .. "\n```\n")
    f:close()
  end
  T.ok(#clean_txt > 100)
end)

return true
