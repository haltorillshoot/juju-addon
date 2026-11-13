-- tests/harness.lua : builds a full simulated world and boots the addon into it
local Mock = require("mock")

local H = {}
H.Mock = Mock

-- opts: config (USER_CONFIG), drawing=false, override, no_juju, pre(ctx), bundle=path (use dist file)
function H.boot(opts)
  opts = opts or {}
  local sim = Mock.Sim.new()
  local g = Mock.Game.new(sim)
  local me = g:add_player("Me", 1, true)
  local J = Mock.new_juju(sim, g)
  local drawing = (opts.drawing ~= false) and Mock.new_drawing() or nil
  local env = Mock.env(sim, g, J, { drawing = drawing, override = opts.override, no_juju = opts.no_juju })
  local ctx = { sim = sim, g = g, J = J, me = me, env = env, drawing = drawing, enemies = {} }
  if opts.pre then opts.pre(ctx) end
  local inst, err
  local bundle = opts.bundle or JHC_BUNDLE
  if bundle then
    -- run the shipped single-file bundle against the same mock environment
    env.genv.JHC_CONFIG = opts.config            -- the documented way to configure the bundle
    local f = assert(loadfile(bundle))
    -- globals the bundle reads come from the mock; `os.clock` must be the VIRTUAL clock
    -- the bundle reads os.clock: expose whatever clock the (possibly overridden) mock env carries
    local fake_os = { clock = (type(env.os_clock) == "function") and env.os_clock or nil,
      time = os.time, date = os.date }
    local genv = setmetatable({}, { __index = function(_, k)
      if k == "os" then return fake_os end
      local v = env[k]
      if v ~= nil then return v end
      return _G[k]
    end })
    setfenv(f, genv)
    inst, err = f()
  else
    inst, err = require("main").start(opts.config, env)
  end
  ctx.inst, ctx.err = inst, err
  return ctx
end

-- Standard world: me spawned with a tool equipped, n enemies spawned. Built BEFORE the addon
-- loads (like loading Juju into a running game) unless opts.late_boot.
function H.standard(opts)
  opts = opts or {}
  local ctx
  ctx = H.boot({
    config = opts.config, drawing = opts.drawing, override = opts.override, bundle = opts.bundle,
    pre = function(c)
      c.J.ping = opts.ping or 60
      c.g:spawn(c.me)
      local n = opts.enemies or 2
      for i = 1, n do
        local p = c.g:add_player("Enemy" .. i, 100 + i)
        c.g:spawn(p)
        c.enemies[i] = p
      end
      if opts.tool ~= false then
        c.tool = c.g:give_tool(c.me, opts.tool_name or "[Double-Barrel SG]",
          { ammo = opts.ammo, attr_ammo = opts.attr_ammo, max_ammo = opts.max_ammo })
        c.g:equip(c.me, c.tool)
      end
      if opts.pre then opts.pre(c) end
    end,
  })
  return ctx
end

function H.shoot(ctx, tool)
  (tool or ctx.tool).Activated:Fire()
end

-- schedule a health drop on `enemy` after `delay` seconds
function H.damage_after(ctx, enemy, delay, dmg)
  ctx.sim.task.delay(delay, function()
    if enemy.hum then enemy.hum:SetHealth(enemy.hum.Health - (dmg or 20)) end
  end)
end

-- shoot now; the server "registers" the hit `delay` seconds later
function H.shoot_hit(ctx, enemy, delay, dmg)
  H.shoot(ctx)
  H.damage_after(ctx, enemy, delay or 0.07, dmg)
end

function H.run(ctx, secs) ctx.sim:advance(secs) end

-- run long enough for every pending shot to resolve
function H.settle(ctx, secs) ctx.sim:advance(secs or 3) end

function H.stats(ctx, name) return ctx.inst.engine:stats(name or "all") end

-- invariant: attempted = hit + miss + unconfirmed + not_fired + pending (all buckets)
function H.check_invariant(ctx, T)
  local eng = ctx.inst.engine
  local names = eng:bucket_names()
  for i = 1, #names do
    local s = eng:stats(names[i])
    T.eq(s.attempted, s.hits + s.misses + s.unconfirmed + s.not_fired + s.pending,
      "invariant broken in bucket " .. names[i])
    T.ok(s.pending >= 0, "negative pending in " .. names[i])
  end
  local all = eng:stats("all")
  T.eq(all.pending, eng:pending_count(), "pending counter disagrees with pending list")
end

function H.clean_sim(ctx, T)
  T.eq(#ctx.sim.errors, 0, "scheduler errors: " .. table.concat(ctx.sim.errors, " | "))
end

return H
