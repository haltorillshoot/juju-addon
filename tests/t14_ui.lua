local T = require("tf")
local H = require("harness")

T.suite("14 UI functionality")

local function find_line(lines, sub)
  for _, l in ipairs(lines) do
    if string.find(l, sub, 1, true) then return l end
  end
end

T.test("menu layout: two sections, documented element types, sensible slider ranges", function()
  local c = H.standard()
  local names = {}
  for _, e in ipairs(c.J.elements) do names[e.section .. "/" .. e.info.name] = e.info end
  T.ok(names["Hit Checker/Enabled"] and names["Hit Checker/Enabled"].type == "toggle")
  T.ok(names["Hit Checker/Reset stats"] and names["Hit Checker/Print report"])
  T.eq(names["Hit Checker/Max window ms"].type, "slider")
  T.ok(names["Hit Checker/Max window ms"].min < names["Hit Checker/Max window ms"].max)
  T.ok(names["Auto Mode/Auto Mode DBS"] and names["Auto Mode/Follow Juju auto"])
  T.eq(c.J.tab_text, "HitCheck")
end)

T.test("controls start in sync with the configuration and do not fire handlers", function()
  local c = H.standard({ config = { hud = false, auto_mode = true, window_max = 2.0 } })
  T.eq(c.J.element("Hit Checker", "Show HUD").value, false)
  T.eq(c.J.element("Auto Mode", "Auto Mode DBS").value, true)
  T.eq(c.J.element("Hit Checker", "Max window ms").value, 2000)
  T.eq(c.inst.cfg.window_max, 2.0)
  T.eq(c.inst.auto.state, "ACTIVE", "auto_mode from config is active at once")
end)

T.test("Enabled toggle stops/starts tracking AND the sampler (no duplicate samplers)", function()
  local c = H.standard()
  H.run(c, 5)
  local n0 = c.inst.diag.n_samples
  c.J.user_set("Hit Checker", "Enabled", false)
  H.run(c, 10)
  T.ok(c.inst.diag.n_samples <= n0 + 1, "sampler kept running while disabled")
  H.shoot(c); H.settle(c)
  T.eq(H.stats(c).attempted, 0)
  c.J.user_set("Hit Checker", "Enabled", true)
  c.J.user_set("Hit Checker", "Enabled", false)
  c.J.user_set("Hit Checker", "Enabled", true)    -- rapid flapping
  local n1 = c.inst.diag.n_samples
  H.run(c, 10)
  local gained = c.inst.diag.n_samples - n1
  T.ok(gained >= 9 and gained <= 11, "expected ~10 samples with ONE sampler, got " .. gained)
  H.shoot(c); H.settle(c)
  T.eq(H.stats(c).attempted, 1)
end)

T.test("a failing sampler start leaves no half-started state and can be retried", function()
  local c = H.standard()
  c.J.user_set("Hit Checker", "Enabled", false)
  H.run(c, 3)
  local real_spawn = c.sim.task.spawn
  c.sim.task.spawn = function() error("spawn unavailable") end
  c.J.user_set("Hit Checker", "Enabled", true)       -- handler error is contained and logged
  T.falsy(c.inst.world.sampler_on, "flag must not claim a sampler that does not exist")
  c.sim.task.spawn = real_spawn
  c.J.user_set("Hit Checker", "Enabled", false)
  c.J.user_set("Hit Checker", "Enabled", true)
  local n0 = c.inst.diag.n_samples
  H.run(c, 5)
  T.ok(c.inst.diag.n_samples >= n0 + 4, "sampler must run after the retry")
end)

T.test("syncing the menu never rewrites the user's configuration", function()
  local c = H.standard({ config = { window_max = 1.2345, window_min = 0.1234, scope = "all", hud = false } })
  T.eq(c.inst.cfg.window_max, 1.2345)
  T.eq(c.inst.cfg.window_min, 0.1234)
  T.eq(c.inst.cfg.scope, "all")
  T.eq(c.inst.cfg.hud, false)
  T.eq(#c.sim.errors, 0)
end)

T.test("HUD: nine lines, content tracks the statistics", function()
  local c = H.standard()
  H.run(c, 0.6)
  T.eq(c.drawing.live, 9)
  local lines = c.inst.ui:lines()
  T.eq(#lines, 9)
  T.contains(find_line(lines, "Weapon"), "[DBS]")
  T.contains(find_line(lines, "Auto Mode"), "OFF")
  H.shoot_hit(c, c.enemies[1], 0.07, 10); H.run(c, 1)
  H.shoot(c); H.run(c, 1)
  local l = find_line(c.inst.ui:lines(), "Shots")
  T.contains(l, "Shots 2"); T.contains(l, "Hit 1"); T.contains(l, "Miss 1")
  T.contains(find_line(c.inst.ui:lines(), "Hit%"), "50.0%")
  T.contains(find_line(c.inst.ui:lines(), "Ping"), "60ms")
  -- the drawing objects received it
  local shown = {}
  for _, o in ipairs(c.drawing.objects) do shown[#shown + 1] = o.Text end
  T.contains(table.concat(shown, "\n"), "Shots 2")
end)

T.test("HUD refresh is throttled: a flood of events causes at most a couple of renders", function()
  local c = H.standard()
  H.run(c, 1)
  local before = c.inst.ui.renders
  for i = 1, 1000 do c.inst.ui:mark_dirty() end
  for i = 1, 50 do c.inst.engine:reset() end
  H.run(c, 0.2)
  T.ok(c.inst.ui.renders - before <= 2, "renders: " .. (c.inst.ui.renders - before))
end)

T.test("HUD only rewrites lines whose text changed", function()
  local c = H.standard()
  H.run(c, 4)
  local function writes()
    local n = 0
    for _, o in ipairs(c.drawing.objects) do n = n + o.text_sets end
    return n
  end
  T.ok(writes() >= 9, "the mock must really observe the initial writes (guards against a vacuous test)")
  local w0 = writes()
  H.run(c, 20)                           -- steady state: ping constant, nothing happens
  T.eq(writes(), w0, "Drawing.Text rewritten without any change")
  local before = {}
  for i, o in ipairs(c.drawing.objects) do before[i] = o.text_sets end
  H.shoot(c); H.run(c, 1)                -- one shot, one miss
  -- lines: 1 header, 2 weapon, 3 auto mode, 4 shots, 5 hit%, 6 auto/manual, 7 ping, 8 window, 9 last
  for _, i in ipairs({ 1, 2, 3, 7, 8 }) do
    T.eq(c.drawing.objects[i].text_sets, before[i], "line " .. i .. " must not be rewritten")
  end
  for _, i in ipairs({ 4, 5, 6, 9 }) do
    T.ok(c.drawing.objects[i].text_sets > before[i], "line " .. i .. " must have been updated")
  end
  T.ok(writes() - w0 <= 8, "unexpected number of rewrites: " .. (writes() - w0))
end)

T.test("Show HUD toggle hides / shows every line", function()
  local c = H.standard()
  H.run(c, 0.6)
  for _, o in ipairs(c.drawing.objects) do T.eq(o.Visible, true) end
  c.J.user_set("Hit Checker", "Show HUD", false)
  for _, o in ipairs(c.drawing.objects) do T.eq(o.Visible, false) end
  H.run(c, 2)
  for _, o in ipairs(c.drawing.objects) do T.eq(o.Visible, false) end
  c.J.user_set("Hit Checker", "Show HUD", true)
  H.run(c, 0.6)
  for _, o in ipairs(c.drawing.objects) do T.eq(o.Visible, true) end
end)

T.test("Drawing failure: HUD disabled, summary moves to the tab text, no crash", function()
  local c = H.standard({ pre = function(x) x.drawing.fail = true end })
  H.run(c, 1)
  T.ok(c.inst.ui.hud_failed)
  T.eq(c.J.tab_text, "H0 M0 -")
  H.shoot_hit(c, c.enemies[1], 0.07, 10); H.run(c, 1)
  T.eq(c.J.tab_text, "H1 M0 100%")
  T.eq(#c.sim.errors, 0)
end)

T.test("No Drawing library at all behaves the same way", function()
  local c = H.standard({ drawing = false })
  H.run(c, 1)
  T.falsy(c.inst.host.caps.drawing)
  T.eq(c.J.tab_text, "H0 M0 -")
end)

T.test("Live tab summary toggle; tab text never exceeds 12 characters", function()
  local c = H.standard()
  H.run(c, 1)
  T.eq(c.J.tab_text, "HitCheck")
  c.J.user_set("Hit Checker", "Live tab summary", true)
  H.run(c, 1)
  T.eq(c.J.tab_text, "H0 M0 -")
  local b = c.inst.engine.buckets.all
  b.hits, b.misses, b.attempted = 123456, 98765, 222221
  T.ok(#c.inst.ui:tab_text() <= 12)
  for i = 1, #c.J.calls do
    if c.J.calls[i].name == "set_tab_text" then T.ok(#c.J.calls[i].args[1] <= 12) end
  end
end)

T.test("sliders: window bounds and scope mapping, out-of-range input is clamped", function()
  local c = H.standard()
  c.J.user_set("Hit Checker", "Max window ms", 1200)
  c.J.user_set("Hit Checker", "Min window ms", 300)
  T.near(c.inst.cfg.window_max, 1.2, 1e-9); T.near(c.inst.cfg.window_min, 0.3, 1e-9)
  local cases = { { 1, "auto" }, { 2, "target" }, { 3, "all" }, { 0, "auto" }, { 7, "all" }, { 2.4, "target" } }
  for _, k in ipairs(cases) do
    c.J.user_set("Auto Mode", "Scope 1auto 2tgt 3all", k[1])
    T.eq(c.inst.cfg.scope, k[2], "slider " .. k[1])
  end
  c.J.user_set("Hit Checker", "Max window ms", 250)       -- below the current min (0.3)
  T.near(c.inst.cfg.window_max, 0.25, 1e-9); T.near(c.inst.cfg.window_min, 0.25, 1e-9, "min dragged down")
  c.J.user_set("Hit Checker", "Min window ms", 1000)      -- above the current max
  T.near(c.inst.cfg.window_min, 1.0, 1e-9); T.near(c.inst.cfg.window_max, 1.0, 1e-9, "max dragged up")
  T.ok(c.inst.cfg.window_min <= c.inst.cfg.window_max)
  c.J.user_set("Hit Checker", "Max window ms", "garbage")
  T.eq(#c.sim.errors, 0)
end)

T.test("Debug log toggle controls console output", function()
  local c = H.standard()
  local n0 = #c.env.output
  H.shoot(c); H.run(c, 1)
  T.eq(#c.env.output, n0, "silent when debug is off")
  c.J.user_set("Hit Checker", "Debug log", true)
  H.shoot(c); H.run(c, 1)
  T.ok(#c.env.output > n0)
  local joined = table.concat(c.env.output, "\n")
  T.contains(joined, "shot:")
  T.contains(joined, "miss:")
  c.J.user_set("Hit Checker", "Debug log", false)
  local n1 = #c.env.output
  H.shoot(c); H.run(c, 1)
  T.eq(#c.env.output, n1)
end)

T.test("Print report writes the diagnostics to the console and resets the toggle", function()
  local c = H.standard({ ammo = 2 })
  H.shoot_hit(c, c.enemies[1], 0.07, 10); H.run(c, 1)
  c.J.user_set("Hit Checker", "Print report", true)
  T.eq(c.J.element("Hit Checker", "Print report").value, false)
  local joined = table.concat(c.env.output, "\n")
  for _, needle in ipairs({ "JHC report", "att=1 hit=1", "unconfirmed reasons", "ping=60ms", "capabilities",
    "last events", "limits:", "ammo_source=value:Ammo", "mode:manual", "weapon:doublebarrelsg" }) do
    T.contains(joined, needle)
  end
end)

T.test("late callbacks after unload are inert", function()
  local c = H.standard()
  c.J.unload()
  T.no_error(function()
    c.J.user_set("Hit Checker", "Enabled", false)
    c.J.user_set("Hit Checker", "Reset stats", true)
    c.J.user_set("Auto Mode", "Auto Mode DBS", true)
  end)
  T.eq(c.inst.cfg.enabled, true)
  T.eq(c.inst.auto.state, "OFF")
end)

T.test("destroy removes every Drawing object", function()
  local c = H.standard()
  H.run(c, 1)
  T.eq(c.drawing.live, 9)
  c.inst.shutdown("test")
  T.eq(c.drawing.live, 0)
end)

return true
