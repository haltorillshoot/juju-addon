-- main.lua
-- Composition root: builds the modules, wires them together, registers the unload hook FIRST
-- (so a failure half-way through init is still cleaned up), guards against double loading.

local U = require("util")
local Config = require("config")
local Host = require("host")
local Diag = require("diag")
local Engine = require("engine")
local Auto = require("automode")
local World = require("world")
local UI = require("ui")

local M = {}

-- user_cfg: optional table (see config.lua); env: optional environment table (tests)
-- Returns inst on success, or nil, "reason".
function M.start(user_cfg, env)
  env = env or Host.default_env()
  local host, herr = Host.detect(env)
  if not host then
    local p = type(env) == "table" and env.print or print
    if type(p) == "function" then pcall(p, "[JHC] init failed: " .. tostring(herr)) end
    return nil, herr
  end

  -- duplicate-load guard: shut an older instance down before replacing it
  local reg = host.registry()
  local prev = reg.__JHC_INSTANCE
  if type(prev) == "table" and type(prev.shutdown) == "function" then
    host.say("previous instance found - shutting it down before reload")
    pcall(prev.shutdown, "reload")
  end

  local cfgobj = Config.new(user_cfg)
  local cfg = cfgobj.values
  local logger = U.make_logger(cfg, host.say, cfg.log_size)
  local log = logger.log
  local inst = { version = Config.VERSION, host = host, cfgobj = cfgobj, cfg = cfg, dead = false,
                 errors = 0, logger = logger }
  local engine, diag, auto, bag, world, ui

  function inst.shutdown(reason)
    if inst.dead then return end
    inst.dead = true
    if world then pcall(world.stop, world) end
    if bag then pcall(bag.clear, bag) end
    if engine then pcall(engine.shutdown, engine) end
    if ui then pcall(ui.destroy, ui) end
    if reg.__JHC_INSTANCE == inst then reg.__JHC_INSTANCE = nil end
    pcall(host.set_flag, "jhc_loaded", false)       -- other addons must not see a stale "loaded"
    host.say("unloaded (" .. tostring(reason or "unload") .. ")")
  end

  local ok, err = pcall(function()
    -- 1. cleanup hook before anything that can leak
    host.juju.on_unload(function() inst.shutdown("unload") end)

    -- 2. configuration (defaults < USER_CONFIG < jhc_cfg_* flags)
    local applied = cfgobj:load_flags(host.get_flag)
    if applied > 0 then log("info", applied .. " setting(s) loaded from jhc_cfg_* flags") end
    for i = 1, #cfgobj.problems do log("warn", "config: " .. cfgobj.problems[i]) end

    -- 3. modules
    local function ui_dirty() if ui then ui:mark_dirty() end end
    local timers = {
      delay = function(sec, fn) return host.task.delay(sec, fn) end,
      cancel = function(h) if h ~= nil and host.caps.task_cancel then host.task.cancel(h) end end,
    }
    diag = Diag.new({ cfg = cfg, now = host.clock, get_ping = host.ping, get_gap = host.gap, log = log })
    auto = Auto.new({ cfg = cfg, log = log, on_change = ui_dirty })
    engine = Engine.new({ cfg = cfg, now = host.clock, timers = timers, diag = diag, log = log,
                          on_change = ui_dirty })
    local err_counts = {}
    bag = U.Bag.new(host.connect, function(key, e)
      inst.errors = inst.errors + 1
      -- a handler failing on every event must not flood the console: first 3, then every 100th
      local n = (err_counts[key] or 0) + 1
      err_counts[key] = n
      if n <= 3 or n % 100 == 0 then
        log("error", string.format("handler '%s' (failure #%d): %s", tostring(key), n, tostring(e)))
      end
    end)
    world = World.new({ host = host, cfg = cfg, engine = engine, diag = diag, auto = auto, bag = bag,
                        log = log, ui_dirty = ui_dirty })

    local actions = {}
    function actions.reset()
      engine:reset()
      diag:reset()
      diag:sample("reset")
      log("info", "statistics reset")
      ui_dirty()
    end
    function actions.dump()
      local report = ui:report()
      for line in string.gmatch(report, "[^\n]+") do host.say(line) end
    end
    function actions.apply_enabled()
      if cfg.enabled then world:start_sampler() else world:stop_sampler() end
    end

    ui = UI.new({ host = host, cfgobj = cfgobj, engine = engine, diag = diag, auto = auto, world = world,
                  actions = actions, log = log })

    -- 4. menu (non-fatal), world, sampler
    ui:build_menu()
    world:start()
    host.probe_connect(function(mode)
      if mode == "noop_returns_nil" then
        log("warn", "juju.create_connection did nothing here (not loaded as a Juju addon?): using direct "
          .. "connections; they are released by this addon's own unload hook")
      elseif mode == "connects_returns_nil" then
        log("warn", "juju.create_connection connects but returns no connection object: listeners may be "
          .. "registered twice (host.dup_risk)")
      elseif mode ~= "returns_connection" then
        log("warn", "juju.create_connection behaves unexpectedly: " .. tostring(mode))
      end
    end)
    if cfg.enabled then
      diag:sample("init")
      world:start_sampler()
    end
    auto:set_enabled(cfg.auto_mode)
    host.set_flag("jhc_loaded", true)
    ui:mark_dirty()
  end)

  if not ok then
    log("error", "init failed: " .. tostring(err))
    inst.shutdown("init_failed")
    return nil, tostring(err)
  end

  inst.engine, inst.diag, inst.auto, inst.world, inst.ui, inst.bag = engine, diag, auto, world, ui, bag
  function inst.stats(name) return engine:stats(name) end
  function inst.report() return ui:report() end
  function inst.reset() engine:reset(); diag:reset() end

  reg.__JHC_INSTANCE = inst
  host.say(string.format("v%s loaded (menu=%s hud=%s weapons: aliases=%s)", Config.VERSION,
    tostring(ui.menu_ok), tostring(host.caps.drawing), table.concat(cfg.weapon_aliases, "/")))
  return inst
end

return M
