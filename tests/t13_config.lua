local T = require("tf")
local H = require("harness")
local Config = require("config")

T.suite("13 Configuration loading")

T.test("defaults: every schema key has a default and a valid value", function()
  local cfg, problems = Config.sanitize(nil)
  T.eq(#problems, 0)
  for k in pairs(Config.schema) do
    T.ok(cfg[k] ~= nil, "no default for " .. k)
  end
  for k in pairs(Config.defaults) do
    T.ok(Config.schema[k], "default without schema: " .. k)
  end
  T.ok(cfg.window_min <= cfg.window_default and cfg.window_default <= cfg.window_max)
end)

T.test("sanitize: wrong top-level type is ignored with a report", function()
  local cfg, problems = Config.sanitize("nonsense")
  T.eq(cfg.scope, "auto")
  T.ok(#problems >= 1)
end)

T.test("sanitize: numeric strings are coerced, junk keeps the default", function()
  local cfg, problems = Config.sanitize({ window_min = "0.4", hud_size = "huge", ui_refresh = {} })
  T.near(cfg.window_min, 0.4, 1e-9)
  T.eq(cfg.hud_size, Config.defaults.hud_size)
  T.eq(cfg.ui_refresh, Config.defaults.ui_refresh)
  T.eq(#problems, 2)
end)

T.test("sanitize: out-of-range numbers are clamped and reported", function()
  local cfg, problems = Config.sanitize({ window_max = 9999, ewma_alpha = -1, diag_samples = 1e9 })
  T.eq(cfg.window_max, 10); T.eq(cfg.ewma_alpha, 0.01); T.eq(cfg.diag_samples, 512)
  T.eq(#problems, 3)
end)

T.test("sanitize: NaN / inf are rejected", function()
  local cfg = Config.sanitize({ window_min = 0 / 0, window_max = math.huge })
  T.eq(cfg.window_min, Config.defaults.window_min)
  T.eq(cfg.window_max, Config.defaults.window_max)
end)

T.test("sanitize: enum is case-insensitive, unknown value rejected", function()
  T.eq(Config.sanitize({ scope = "TARGET" }).scope, "target")
  T.eq(Config.sanitize({ scope = "everyone" }).scope, "auto")
end)

T.test("sanitize: boolean coercions", function()
  local cfg = Config.sanitize({ hud = "false", debug = 1, enabled = "maybe", tab_summary = 0 })
  T.eq(cfg.hud, false); T.eq(cfg.debug, true); T.eq(cfg.enabled, true); T.eq(cfg.tab_summary, false)
end)

T.test("sanitize: string lists are normalised; empty lists are rejected", function()
  local cfg = Config.sanitize({ weapon_aliases = "Double Barrel, DB-SG ; x1y", ammo_patterns = {} })
  T.eq(table.concat(cfg.weapon_aliases, "|"), "doublebarrel|dbsg|xy")
  T.eq(table.concat(cfg.ammo_patterns, "|"), table.concat(Config.defaults.ammo_patterns, "|"))
  local cfg2 = Config.sanitize({ weapon_aliases = { "A-B", "", 5 } })
  T.eq(table.concat(cfg2.weapon_aliases, "|"), "ab")
end)

T.test("sanitize: defaults table is never aliased (mutation safe)", function()
  local a = Config.sanitize(nil)
  a.weapon_aliases[1] = "mutated"
  local b = Config.sanitize(nil)
  T.eq(b.weapon_aliases[1], "doublebarrel")
end)

T.test("sanitize: window_min > window_max falls back to defaults together", function()
  local cfg, problems = Config.sanitize({ window_min = 2, window_max = 0.5 })
  T.eq(cfg.window_min, Config.defaults.window_min)
  T.eq(cfg.window_max, Config.defaults.window_max)
  T.ok(#problems >= 1)
end)

T.test("sanitize: window_default is clamped into [min, max]", function()
  local cfg = Config.sanitize({ window_min = 0.3, window_max = 0.5, window_default = 3 })
  T.eq(cfg.window_default, 0.5)
end)

T.test("runtime set(): valid, invalid, unknown, listener notification", function()
  local obj = Config.new()
  local seen = {}
  obj:on_change(function(k, v) seen[#seen + 1] = k .. "=" .. tostring(v) end)
  T.ok(obj:set("scope", "all"))
  T.eq(obj.values.scope, "all")
  local ok, why = obj:set("scope", "nope")
  T.falsy(ok); T.ok(why)
  T.eq(obj.values.scope, "all", "invalid set must not change the value")
  T.falsy(obj:set("no_such_key", 1))
  T.eq(#seen, 1); T.eq(seen[1], "scope=all")
end)

T.test("runtime set(): a throwing listener cannot break the setter", function()
  local obj = Config.new()
  obj:on_change(function() error("listener bug") end)
  T.ok(obj:set("hud", false))
  T.eq(obj.values.hud, false)
end)

T.test("flags jhc_cfg_<key> override USER_CONFIG; invalid flags are rejected and reported", function()
  local c = H.standard({
    config = { scope = "all", window_min = 0.3 },
    pre = function(x)
      x.J.flags.jhc_cfg_scope = "target"
      x.J.flags.jhc_cfg_hud = "banana"
      x.J.flags.jhc_cfg_window_max = "2.0"
    end,
  })
  local cfg = c.inst.cfg
  T.eq(cfg.scope, "target", "flag beats file")
  T.near(cfg.window_min, 0.3, 1e-9, "file beats default")
  T.near(cfg.window_max, 2.0, 1e-9)
  T.eq(cfg.hud, true, "invalid flag value did not apply")
  local joined = table.concat(c.inst.cfgobj.problems, ";")
  T.contains(joined, "hud")
end)

T.test("config actually changes behaviour at runtime (scope, window bounds)", function()
  local c = H.standard({ enemies = 2, config = { scope = "target" } })
  -- scope=target with no ragebot target: nothing observable
  H.shoot_hit(c, c.enemies[1], 0.07, 10); H.settle(c)
  T.eq(c.inst.engine.last_shot.reason, "no_observable_target")
  c.J.user_set("Auto Mode", "Scope 1auto 2tgt 3all", 3)
  T.eq(c.inst.cfg.scope, "all")
  H.run(c, 1)
  H.shoot_hit(c, c.enemies[1], 0.07, 10); H.settle(c)
  T.eq(c.inst.engine.last_shot.outcome, "hit")
end)

T.test("custom dedupe_eps / burst_gap are honoured", function()
  local c = H.standard({ config = { dedupe_eps = 0.1 } })
  H.shoot(c); H.run(c, 0.05); H.shoot(c)
  H.settle(c)
  T.eq(H.stats(c).attempted, 1)
  T.eq(H.stats(c).deduped, 1)
end)

return true
