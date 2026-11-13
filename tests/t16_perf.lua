local T = require("tf")
local H = require("harness")
local Signal = H.Mock.Signal

T.suite("16 Performance and stability")

T.test("idle: one sampler wake per second, no timer buildup, no per-second flag/draw churn", function()
  local c = H.standard()
  H.run(c, 5)
  local waits0, ping0 = c.sim.stats.waits, c.J.count_calls("get_ping")
  local flags0 = c.J.count_calls("set_flag")
  local writes0 = 0
  for _, o in ipairs(c.drawing.objects) do writes0 = writes0 + o.text_sets end
  H.run(c, 60)
  T.ok(c.sim.stats.waits - waits0 <= 61, "task.wait wakes: " .. (c.sim.stats.waits - waits0))
  T.ok(c.J.count_calls("get_ping") - ping0 <= 61)
  T.eq(c.J.count_calls("set_flag"), flags0, "flags rewritten while nothing changed")
  local writes1 = 0
  for _, o in ipairs(c.drawing.objects) do writes1 = writes1 + o.text_sets end
  T.eq(writes1, writes0, "HUD rewritten while nothing changed")
  T.ok(c.sim:pending_timers() <= 3, "pending timers: " .. c.sim:pending_timers())
end)

T.test("disabled: zero background work", function()
  local c = H.standard()
  c.J.user_set("Hit Checker", "Enabled", false)
  H.run(c, 3)
  local waits0, ping0 = c.sim.stats.waits, c.J.count_calls("get_ping")
  H.run(c, 120)
  T.eq(c.sim.stats.waits, waits0)
  T.eq(c.J.count_calls("get_ping"), ping0)
end)

T.test("throughput: the engine alone handles 50000 shot+hit cycles quickly", function()
  local Engine = require("engine")
  local Config = require("config")
  local cfg = Config.new().values
  local now = 0
  local diag = { window = function() return 0.25 end, degraded_between = function() return false end,
    note_latency = function() end }
  local eng = Engine.new({ cfg = cfg, now = function() return now end, diag = diag,
    timers = { delay = function() return {} end, cancel = function() end } })
  local w = { key = "x", name = "x", is_dbs = false }
  local t0 = os.clock()
  for i = 1, 50000 do
    now = now + 0.5
    eng:register_shot({ weapon = w, candidates = { [1] = true }, ncand = 1, ping_ms = 50 })
    now = now + 0.07
    eng:register_damage({ uid = 1, amount = 5 })
  end
  local dt = os.clock() - t0
  T.ok(dt < 2, string.format("took %.2fs", dt))
  T.eq(eng:stats("all").hits, 50000)
  T.eq(eng:pending_count(), 0)
  print(string.format("      [perf] engine only, 50000 shot+hit cycles: %.3fs (%.2f us each)", dt, dt / 50000 * 1e6))
end)

T.test("throughput: 5000 cycles through the whole addon + mock stay within a sane bound", function()
  local c = H.standard({ enemies = 1 })
  c.J.record = false
  local eng = c.inst.engine
  local w = { key = "x", name = "x", is_dbs = false }
  local t0 = os.clock()
  for i = 1, 5000 do
    c.sim:advance(0.5)
    eng:register_shot({ weapon = w, candidates = { [1] = true }, ncand = 1, ping_ms = 50 })
    c.sim:advance(0.07)
    eng:register_damage({ uid = 1, amount = 5 })
  end
  local dt = os.clock() - t0
  T.ok(dt < 10, string.format("took %.2fs", dt))
  T.eq(eng:stats("all").hits, 5000)
  print(string.format("      [perf] full stack incl. mock scheduler, 5000 cycles: %.3fs", dt))
end)

T.test("memory: rings are bounded and 5000 end-to-end shots do not grow the heap", function()
  local c = H.standard({ enemies = 2 })
  c.J.record = false                     -- the Juju mock's own call log would otherwise dominate the heap
  local function cycle(n)
    for i = 1, n do
      H.shoot(c)
      if i % 2 == 0 then H.damage_after(c, c.enemies[1], 0.07, 1) end
      H.run(c, 0.6)
    end
  end
  cycle(500)                                           -- warm up
  collectgarbage("collect"); collectgarbage("collect")
  local before = collectgarbage("count")
  cycle(5000)
  collectgarbage("collect"); collectgarbage("collect")
  local after = collectgarbage("count")
  T.ok(after - before < 256, string.format("heap grew %.1f KB", after - before))
  local eng = c.inst.engine
  T.ok(eng.events:size() <= c.inst.cfg.log_size)
  T.ok(c.inst.diag.samples:size() <= c.inst.cfg.diag_samples)
  T.eq(eng:pending_count(), 0)
  T.eq(next(eng.by_id), nil, "by_id must be empty")
  T.ok(eng.recent_miss:size() <= 16)
  H.check_invariant(c, T)
  print(string.format("      [perf] heap delta over 5000 shots: %.1f KB", after - before))
end)

T.test("connection count is constant under churn (respawn + switch + join/leave)", function()
  local c = H.standard({ enemies = 2 })
  local b = c.g:give_tool(c.me, "[Revolver]")
  c.g:despawn(c.me); c.g:spawn(c.me)
  local a = c.g:give_tool(c.me, "[Double-Barrel SG]")
  c.g:equip(c.me, a)
  local base = Signal.live_total
  for i = 1, 100 do
    c.g:unequip(c.me, a); c.g:equip(c.me, b); c.g:unequip(c.me, b); c.g:equip(c.me, a)
    local p = c.g:add_player("P" .. i, 5000 + i); c.g:spawn(p); c.g:despawn(p); c.g:spawn(p); c.g:remove_player(p)
  end
  T.eq(Signal.live_total, base, "connection drift: " .. (Signal.live_total - base))
end)

T.test("1000 rapid activations: pending list handled, all resolved, invariant holds", function()
  local c = H.standard()
  for i = 1, 1000 do H.shoot(c); c.sim:advance(0.03) end
  T.ok(H.stats(c).pending > 0)
  H.settle(c, 5)
  T.eq(H.stats(c).pending, 0)
  T.eq(H.stats(c).attempted, 1000)
  H.check_invariant(c, T)
  T.eq(#c.sim.errors, 0)
end)

T.test("UI cost: renders and flag writes stay proportional to time, not to events", function()
  local c = H.standard()
  H.run(c, 1)
  local r0, f0 = c.inst.ui.renders, c.inst.ui.flag_writes
  for i = 1, 400 do
    H.shoot(c)
    if i % 3 == 0 then H.damage_after(c, c.enemies[1], 0.07, 0.01) end
    H.run(c, 0.025)
  end
  H.run(c, 2)
  local seconds = 10 + 2
  T.ok(c.inst.ui.renders - r0 <= seconds / c.inst.cfg.ui_refresh + 3, "renders " .. (c.inst.ui.renders - r0))
  T.ok(c.inst.ui.flag_writes - f0 < 2000)
end)

T.test("long soak: 1 simulated hour with periodic activity stays consistent", function()
  local c = H.standard({ enemies = 3 })
  for minute = 1, 60 do
    for k = 1, 6 do
      H.shoot_hit(c, c.enemies[1 + k % 3], 0.07, 0.001)
      H.run(c, 0.7)
      H.shoot(c)
      H.run(c, 9.3)
    end
  end
  local s = H.stats(c)
  T.eq(s.attempted, 720); T.eq(s.hits, 360); T.eq(s.misses, 360)
  T.eq(#c.sim.errors, 0)
  T.ok(c.sim:pending_timers() <= 3)
  H.check_invariant(c, T)
end)

return true
