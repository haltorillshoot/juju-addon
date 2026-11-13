local T = require("tf")
local H = require("harness")
local U = require("util")
local Signal = H.Mock.Signal

T.suite("15 Error recovery")

T.test("juju.get_ping throws: addon keeps working with the default window", function()
  local c = H.standard({ pre = function(x) x.J.throw.get_ping = true end })
  T.ok(c.inst)
  H.shoot(c); H.settle(c)
  T.near(c.inst.engine.last_shot.window, c.inst.cfg.window_default, 1e-9)
  T.eq(c.inst.engine.last_shot.outcome, "miss")
  T.ok(c.inst.host.errors > 0)
  T.eq(c.inst.diag.n_samples, 0)
  T.eq(#c.sim.errors, 0)
end)

T.test("juju.get_ping returns nonsense: ignored and counted", function()
  local c = H.standard()
  for _, v in ipairs({ "x", 0, -1, 0 / 0, math.huge }) do
    c.J.ping = v
    H.shoot(c); H.run(c, 1)
  end
  T.eq(c.inst.diag.n_invalid >= 5, true)
  T.eq(c.inst.host.invalid_pings >= 5, true)
  T.eq(#c.sim.errors, 0)
end)

T.test("juju.get_flag / set_flag / get_flags throwing do not take the addon down", function()
  local c = H.standard({ pre = function(x)
    x.J.throw.get_flag = true; x.J.throw.set_flag = true; x.J.throw.get_flags = true
  end })
  T.ok(c.inst)
  H.run(c, 5)
  H.shoot_hit(c, c.enemies[1], 0.07, 10); H.run(c, 1)
  T.eq(H.stats(c).hits, 1)
  T.ok(c.inst.host.errors > 0)
  T.eq(c.inst.ui.flag_writes, 0)
  T.eq(#c.sim.errors, 0)
end)

T.test("juju.get_ragebot_target throws: falls back to 'no target' (all players)", function()
  local c = H.standard({ pre = function(x) x.J.throw.get_ragebot_target = true end })
  H.shoot_hit(c, c.enemies[2], 0.07, 10); H.settle(c)
  T.eq(H.stats(c).hits, 1)
end)

T.test("CFrame functions throwing / returning nil: gap is simply unknown", function()
  local c = H.standard({ pre = function(x) x.J.throw.get_server_cframe = true end })
  H.shoot(c); H.settle(c)
  T.is_nil(c.inst.engine.last_shot.gap)
  c.J.throw.get_server_cframe = false
  c.J.client_pos = nil
  T.is_nil(c.inst.host.gap())
end)

T.test("juju.create_connection throwing: init survives, errors are counted, nothing crashes", function()
  local c = H.standard({ pre = function(x) x.J.throw.create_connection = true end })
  T.ok(c.inst, tostring(c.err))
  T.ok(c.inst.errors > 0)
  H.shoot(c); H.run(c, 3)
  T.eq(H.stats(c).attempted, 0)       -- nothing could be connected, so nothing is tracked
  T.eq(#c.sim.errors, 0)
end)

T.test("task.delay failing: the shot is closed as unconfirmed, never stuck pending", function()
  local c = H.standard()
  c.sim.task.delay = function() error("scheduler down") end
  H.shoot(c)
  local s = H.stats(c)
  T.eq(s.pending, 0)
  T.eq(s.unconfirmed, 1)
  T.eq(c.inst.engine.counters.timer_failures, 1)
  T.eq(c.inst.engine.last_shot.reason, "timer_unavailable")
  H.check_invariant(c, T)
end)

T.test("a Tool without an Activated signal is tolerated", function()
  local c = H.standard({ tool = false })
  local t = c.g:give_tool(c.me, "[Broken]")
  t.Activated = nil
  T.no_error(function() c.g:equip(c.me, t) end)
  T.eq(c.inst.world.current.weapon.key, "broken")
end)

T.test("Drawing objects that reject property writes: HUD gives up quietly", function()
  local c = H.standard({ pre = function(x)
    x.drawing.new = function()
      return setmetatable({}, { __newindex = function() error("property write rejected") end })
    end
  end })
  H.run(c, 1)
  T.ok(c.inst.ui.hud_failed)
  H.shoot(c); H.run(c, 1)
  T.eq(#c.sim.errors, 0)
end)

T.test("engine survives failing diagnostics callbacks", function()
  local c = H.standard()
  c.inst.diag.window = function() error("diag broke") end
  c.inst.diag.degraded_between = function() error("diag broke") end
  H.shoot(c); H.settle(c)
  T.near(c.inst.engine.last_shot.window, c.inst.cfg.window_default, 1e-9)
  T.eq(c.inst.engine.last_shot.outcome, "miss")
  T.eq(#c.sim.errors, 0)
end)

T.test("engine API misuse: nil weapon, nil candidates, unknown bucket", function()
  local c = H.standard()
  local eng = c.inst.engine
  local s = eng:register_shot({})
  T.ok(s)
  T.eq(s.weapon.key, "unknown")
  T.eq(s.ncand, 0)
  H.settle(c)
  T.eq(s.outcome, "unconfirmed")
  local z = eng:stats("no-such-bucket")
  T.eq(z.attempted, 0); T.is_nil(z.hit_pct)
  T.no_error(function() eng:target_lost("nobody"); eng:note_context("x") end)
end)

T.test("shutdown is idempotent and the engine goes inert", function()
  local c = H.standard()
  H.shoot(c)
  c.inst.shutdown("a")
  T.no_error(function() c.inst.shutdown("b") end)
  T.eq(c.inst.engine:register_damage({ uid = 1, amount = 5 }), "dead")
  local s, why = c.inst.engine:register_shot({})
  T.is_nil(s); T.eq(why, "dead")
  H.run(c, 5)
  T.eq(#c.sim.errors, 0)
end)

T.test("unload while shots are pending: stray timers do nothing and raise nothing", function()
  local c = H.standard()
  for i = 1, 5 do H.shoot(c); H.run(c, 0.05) end
  c.J.unload()
  H.run(c, 5)
  T.eq(#c.sim.errors, 0)
  T.eq(c.sim:pending_timers(), 0, "timers left behind after unload")
end)

T.test("Bag: a throwing handler is isolated; connect failure reported; keyed replace works", function()
  local errs = {}
  local bag = U.Bag.new(function(sig, fn) return sig:Connect(fn) end, function(k, e) errs[#errs + 1] = k end)
  local sig = Signal.new("s")
  local hits = 0
  bag:set("a", sig, function() hits = hits + 1; error("handler bug") end)
  sig:Fire(); sig:Fire()
  T.eq(hits, 2, "handler still connected after throwing")
  T.eq(#errs, 2)
  bag:set("a", sig, function() hits = hits + 10 end)      -- replace, not stack
  T.eq(sig.live, 1)
  sig:Fire()
  T.eq(hits, 12)
  T.is_nil(bag:set("b", nil, function() end))
  local bad = U.Bag.new(function() error("no") end, function(k) errs[#errs + 1] = "conn:" .. k end)
  T.is_nil(bad:set("x", sig, function() end))
  T.eq(errs[#errs], "conn:x")
  bag:clear()
  T.eq(sig.live, 0); T.eq(bag:size(), 0)
end)

T.test("Bag: drop_prefix only drops matching keys", function()
  local bag = U.Bag.new(function(sig, fn) return sig:Connect(fn) end)
  local s = Signal.new("s")
  bag:set("t:1:a", s, function() end); bag:set("t:1:b", s, function() end); bag:set("t:10:a", s, function() end)
  bag:drop_prefix("t:1:")
  T.eq(bag:size(), 1)
  T.ok(bag:has("t:10:a"))
end)

return true
