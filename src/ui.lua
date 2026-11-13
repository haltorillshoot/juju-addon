-- ui.lua
-- Presentation: Juju menu (documented create_tab / create_section / create_element, element
-- types toggle + slider ONLY), optional Drawing HUD, tab-text summary, jhc_* flag export,
-- and the text report.
--
-- Refreshing is event-driven and throttled: mark_dirty() schedules ONE flush at most every
-- cfg.ui_refresh seconds; a flush re-renders only lines whose text changed. No polling loop.

local U = require("util")
local Config = require("config")

local UI = {}
UI.__index = UI

local SCOPE_BY_NUM = { "auto", "target", "all" }
local NUM_BY_SCOPE = { auto = 1, target = 2, all = 3 }

-- ctx: host, cfgobj, engine, diag, auto, world, actions{reset,dump,apply_enabled}, log
function UI.new(ctx)
  local self = setmetatable({}, UI)
  self.host = ctx.host
  self.cfgobj = ctx.cfgobj
  self.cfg = ctx.cfgobj.values
  self.engine = ctx.engine
  self.diag = ctx.diag
  self.auto = ctx.auto
  self.world = ctx.world
  self.actions = ctx.actions
  self.log = ctx.log or function() end
  self.elements = {}
  self.bound = {}
  self.bag_set = ctx.bag_set      -- keyed connect, so menu signals are released on unload
  self.menu_ok = false
  self.menu_style = "none"
  self.hud = nil
  self.hud_failed = false
  self.dirty = false
  self.scheduled = false
  self.dead = false
  self.last_render = -1e9
  self.flag_cache = {}
  self.tab_text_cache = nil
  self.renders = 0
  self.flag_writes = 0
  return self
end

-- ---------------------------------------------------------------------------------------
-- Text
-- ---------------------------------------------------------------------------------------
local function pct(v)
  if v == nil then return "n/a" end
  return string.format("%.1f%%", v)
end

local function ms(v)
  if v == nil then return "n/a" end
  return string.format("%.0fms", v)
end

function UI:weapon_label()
  local cur = self.world and self.world.current
  if not cur then return "none" end
  return cur.weapon.name .. (cur.weapon.is_dbs and " [DBS]" or "")
end

-- Pure: builds the HUD lines from current state.
function UI:lines()
  local cfg = self.cfg
  local s = self.engine:stats("all")
  local d = self.diag:snapshot()
  local a = self.engine:stats("mode:auto")
  local m = self.engine:stats("mode:manual")
  local c = self.engine.counters
  local L = {}
  L[#L + 1] = string.format("JHC %s  %s", Config.VERSION, cfg.enabled and "[ON]" or "[OFF]")
  L[#L + 1] = string.format("Weapon: %s", self:weapon_label())
  L[#L + 1] = string.format("Auto Mode: %s (%s)", self.auto.state, self.auto.reason)
  L[#L + 1] = string.format("Shots %d  Hit %d  Miss %d  Unconf %d  NoFire %d  Pend %d",
    s.attempted, s.hits, s.misses, s.unconfirmed, s.not_fired, s.pending)
  L[#L + 1] = string.format("Hit%% %s (%d/%d)  Reg%% %s  Juju-conf %d/%d", pct(s.hit_pct), s.hits,
    s.hits + s.misses, pct(s.reg_pct), s.confirmed_hits, s.hits)
  L[#L + 1] = string.format("Auto %d/%d hit  Manual %d/%d hit", a.hits, a.attempted, m.hits, m.attempted)
  L[#L + 1] = string.format("Ping %s avg %s p95 %s jit %s  gap %s", ms(d.ping), ms(d.avg), ms(d.p95),
    ms(d.jitter), d.gap and string.format("%.1f", d.gap) or "n/a")
  L[#L + 1] = string.format("Window %s  spikes %d  stalls %d  late %d  early %d", ms(d.window * 1000),
    d.spikes, d.stalls, c.late_damage, c.early_damage)
  local last = self.engine.last_shot
  if last then
    local what = last.outcome or "pending"
    if last.outcome == "hit" then
      what = string.format("HIT %s", ms(last.latency * 1000))
    elseif last.outcome then
      what = string.upper(last.outcome) .. (last.reason and (" (" .. last.reason .. ")") or "")
    end
    L[#L + 1] = string.format("Last #%d: %s", last.id, what)
  else
    L[#L + 1] = "Last: -"
  end
  return L
end

function UI:tab_text()
  local s = self.engine:stats("all")
  local text = string.format("H%d M%d %s", s.hits, s.misses, s.hit_pct and string.format("%d%%",
    math.floor(s.hit_pct + 0.5)) or "-")
  return string.sub(text, 1, 12)
end

-- Multi-line report for the console (debug/test info).
function UI:report()
  local cfg = self.cfg
  local R = {}
  local function add(fmt, ...) R[#R + 1] = string.format(fmt, ...) end
  add("==== JHC report v%s ====", Config.VERSION)
  add("enabled=%s scope=%s auto_mode=%s state=%s(%s) weapon=%s", tostring(cfg.enabled), cfg.scope,
    tostring(self.auto.enabled), self.auto.state, self.auto.reason, self:weapon_label())
  local names = self.engine:bucket_names()
  for i = 1, #names do
    local s = self.engine:stats(names[i])
    add("[%s] att=%d hit=%d miss=%d unconf=%d nofire=%d pend=%d dedupe=%d hit%%=%s reg%%=%s lat(avg/min/max)=%s/%s/%s dmg=%.1f",
      names[i], s.attempted, s.hits, s.misses, s.unconfirmed, s.not_fired, s.pending, s.deduped,
      pct(s.hit_pct), pct(s.reg_pct), ms(s.lat_avg and s.lat_avg * 1000),
      ms(s.lat_min and s.lat_min * 1000), ms(s.lat_max and s.lat_max * 1000), s.damage)
    if s.hits > 0 then add("      hits also confirmed by Juju's own bullet signal: %d of %d", s.confirmed_hits, s.hits) end
    if s.ratio_avg then add("      hit latency / ping at shot = %.2f (1.0 = exactly one round trip)", s.ratio_avg) end
  end
  local inv_ok, inv_msg = self.engine:check_invariant()
  if not inv_ok then add("!! INTERNAL INVARIANT BROKEN: %s (please report this)", inv_msg) end
  if self.host.clock_suspect then
    add("!! CLOCK WARNING: os.clock disagreed with task.wait; all timing-based verdicts are unreliable")
  end
  local reasons = {}
  for k, v in pairs(self.engine.reasons) do reasons[#reasons + 1] = k .. "=" .. v end
  table.sort(reasons)
  add("unconfirmed reasons: %s", #reasons > 0 and table.concat(reasons, ", ") or "none")
  local c = self.engine.counters
  add("counters: late=%d early=%d unattributed_dmg=%d fires_matched=%d fire_unmatched=%d invalid=%d clock_anomaly=%d timer_fail=%d",
    c.late_damage, c.early_damage, c.unattributed_damage, c.fires_matched, c.fire_unmatched,
    c.invalid_events, c.clock_anomaly, c.timer_failures)
  local d = self.diag:snapshot()
  add("ping=%s avg=%s p95=%s jitter=%s samples=%d invalid=%d spikes=%d stalls=%d gap=%s gap_max=%.1f gap_warns=%d window=%s obs=%d trusted=%d%s",
    ms(d.ping), ms(d.avg), ms(d.p95), ms(d.jitter), d.samples, d.invalid, d.spikes, d.stalls,
    d.gap and string.format("%.1f", d.gap) or "n/a", d.gap_max, d.gap_warns, ms(d.window * 1000),
    d.lat_n, d.tlat_n, d.tlat_p95 and (" p95=" .. ms(d.tlat_p95 * 1000) .. " (window follows this)") or "")
  local cur = self.world and self.world.current
  if cur then
    local iv = self.engine:interval_stats(cur.weapon.key)
    add("weapon key=%s dbs=%s ammo_source=%s%s interval(min/med)=%s", cur.weapon.key, tostring(cur.weapon.is_dbs),
      cur.ammo_kind or "none", cur.ammo_kind and (cur.ammo_validated and " (validated)" or " (unvalidated: not used until it drops on a shot)") or "",
      iv and (ms(iv.min * 1000) .. "/" .. ms(iv.median * 1000)) or "n/a")
  end
  add("targets observed=%d  host_auto=%s  host_flag=%s", self.world and self.world:target_count() or 0,
    tostring(self.auto.ctx.host_auto), tostring(self.world and self.world.host_flag_name or "none"))
  add("menu: %s (%d controls)", self.menu_style, (function()
    local n = 0
    for _ in pairs(self.elements) do n = n + 1 end
    return n
  end)())
  add("juju bullet signal (on_player_bullet_fired, shot source for guns): %s  bullets=%d",
    (self.world and self.world.bullet_hooked) and "hooked" or "not available/disabled",
    self.world and self.world.counts.bullets_seen or 0)
  add("juju native hit signal (on_local_bullet_confirmed): %s  confirms=%d corroborated=%d pellets=%d unmatched=%d",
    (self.world and self.world.juju_confirm_hooked) and "hooked" or "not available/disabled", c.juju_confirms,
    c.corroborated, c.confirm_pellets, c.confirm_unmatched)
  add("connections: create_connection behaviour=%s direct-connect fallbacks=%d%s",
    tostring(self.host.connect_behaviour or "not probed yet"), self.host.connect_fallbacks or 0,
    self.host.dup_risk and "  !! duplicate-listener risk" or "")
  add("-- capabilities --")
  for _, line in ipairs(self.host.caps_lines()) do R[#R + 1] = line end
  if #self.cfgobj.problems > 0 then
    add("-- config problems --")
    for i = 1, #self.cfgobj.problems do R[#R + 1] = "  " .. self.cfgobj.problems[i] end
  end
  add("-- last events --")
  local ev = self.engine:recent_events(12)
  for i = 1, #ev do add("  %.3f %-14s %s", ev[i].t, ev[i].kind, ev[i].text) end
  add("limits: hits = replicated damage on another player after a shot; attribution is probabilistic;")
  add("        misses = no damage in window on a healthy connection; the connection exploit itself is not observable.")
  return table.concat(R, "\n")
end

-- ---------------------------------------------------------------------------------------
-- Juju menu
-- ---------------------------------------------------------------------------------------
function UI:_add(section, info, handler)
  local function cb(val)
    -- self.syncing: we are pushing the current config into the controls; the config already
    -- holds these values, so the handlers must not act (the world is not even started yet)
    if self.dead or self.syncing then return end
    local ok, err = pcall(handler, val)
    if not ok then self.log("error", "ui '" .. info.name .. "': " .. tostring(err)) end
  end
  local ok, el = pcall(function() return section:create_element(info, { callback = cb }) end)
  if not ok then
    self.log("error", "create_element '" .. info.name .. "' failed: " .. tostring(el))
    return nil
  end
  return el
end

local function set_value(el, v)
  if el == nil then return end
  pcall(function() el:set_value(v) end)   -- documented on find_element results only: best effort
end

function UI:_release(el)
  local prev = self.syncing
  self.syncing = true
  set_value(el, false)
  self.syncing = prev
end

-- ---------------------------------------------------------------------------------------
-- Menu
--
-- LIVE FINDING: this Juju build has TWO different element APIs.
--   * addon style (what real addons use):
--         juju.create_element({ name = .., section = .. }, { toggle = { default = .., flag = .. } })
--     The element TYPE is the key of the second table, there is no create_tab/create_section, and
--     the state lives in the bound flag. Elements expose on_toggle_change / set_toggle.
--   * documented style (juju-docs): create_tab -> create_section -> section:create_element(info,
--     { callback = .. }). Called from outside an addon context those return nil and build nothing.
-- The addon style is tried first, the documented one is the fallback, so the menu appears whichever
-- API the host actually provides.
-- ---------------------------------------------------------------------------------------

function UI:_apply(key, v)
  local cfgobj, cfg = self.cfgobj, self.cfg
  if key == "enabled" then
    cfgobj:set("enabled", v)
    if self.actions.apply_enabled then self.actions.apply_enabled() end
    self:mark_dirty()
  elseif key == "hud" then
    cfgobj:set("hud", v); self:apply_hud(); self:mark_dirty()
  elseif key == "debug" then
    cfgobj:set("debug", v)
  elseif key == "tab_summary" then
    cfgobj:set("tab_summary", v); self.tab_text_cache = nil; self:mark_dirty()
  elseif key == "auto_mode" then
    cfgobj:set("auto_mode", v); self.auto:set_enabled(cfg.auto_mode); self:mark_dirty()
  elseif key == "follow_host_auto" then
    cfgobj:set("follow_host_auto", v); self.auto:update({}); self:mark_dirty()
  elseif key == "window_max" then
    if type(v) == "number" then cfgobj:set("window_max", v / 1000) end
  elseif key == "window_min" then
    if type(v) == "number" then cfgobj:set("window_min", v / 1000) end
  elseif key == "scope" then
    if type(v) == "number" then
      local i = math.floor(v + 0.5)
      if i < 1 then i = 1 elseif i > 3 then i = 3 end
      cfgobj:set("scope", SCOPE_BY_NUM[i])
    end
  elseif key == "reset" then
    self.actions.reset()
  elseif key == "report" then
    self.actions.dump()
  end
end

function UI:_specs()
  local cfg = self.cfg
  return {
    { key = "enabled", name = "Enabled", sec = "Hit Checker", kind = "toggle", default = cfg.enabled },
    { key = "hud", name = "Show HUD", sec = "Hit Checker", kind = "toggle", default = cfg.hud },
    { key = "debug", name = "Debug log", sec = "Hit Checker", kind = "toggle", default = cfg.debug },
    { key = "tab_summary", name = "Live tab summary", sec = "Hit Checker", kind = "toggle", default = cfg.tab_summary },
    { key = "reset", name = "Reset stats", sec = "Hit Checker", kind = "button" },
    { key = "report", name = "Print report", sec = "Hit Checker", kind = "button" },
    { key = "window_max", name = "Max window ms", sec = "Hit Checker", kind = "slider",
      min = 250, max = 3000, default = math.floor(cfg.window_max * 1000 + 0.5), suffix = "ms" },
    { key = "window_min", name = "Min window ms", sec = "Hit Checker", kind = "slider",
      min = 100, max = 1000, default = math.floor(cfg.window_min * 1000 + 0.5), suffix = "ms" },
    { key = "auto_mode", name = "Auto Mode DBS", sec = "Auto Mode", kind = "toggle", default = cfg.auto_mode },
    { key = "follow_host_auto", name = "Follow Juju auto", sec = "Auto Mode", kind = "toggle", default = cfg.follow_host_auto },
    { key = "scope", name = "Scope 1auto 2tgt 3all", sec = "Auto Mode", kind = "slider",
      min = 1, max = 3, default = NUM_BY_SCOPE[cfg.scope] or 1 },
  }
end

local function flag_for(spec)
  if spec.kind == "toggle" then return "jhc_cfg_" .. spec.key end   -- shares the config namespace
  return "jhc_ui_" .. spec.key
end

-- Addon style. Returns created_count, failure_reason_if_zero.
function UI:_build_addon_menu()
  local juju = self.host.juju
  local created = 0
  self.bound = {}
  local specs = self:_specs()
  for i = 1, #specs do
    local spec = specs[i]
    local info = { name = spec.name, section = spec.sec }
    local body
    if spec.kind == "slider" then
      body = { slider = { flag = flag_for(spec), min = spec.min, max = spec.max,
                          default = spec.default, suffix = spec.suffix } }
    else
      local def = false
      if spec.kind == "toggle" then def = spec.default and true or false end
      body = { toggle = { flag = flag_for(spec), default = def } }
    end
    local ok, el = pcall(juju.create_element, info, body)
    if not ok then
      if created == 0 then return 0, tostring(el) end   -- wrong API for this host: fall back
      self.log("error", "create_element '" .. spec.name .. "': " .. tostring(el))
    elseif el ~= nil then
      created = created + 1
      self.elements[spec.key] = el
      local rec = { flag = flag_for(spec), spec = spec, last = nil }
      self.bound[#self.bound + 1] = rec
      local sig = nil
      pcall(function() sig = el.on_toggle_change or el.on_slider_change end)
      if sig ~= nil and self.bag_set then
        local wrapped = self.host.wrap_signal(sig)
        if wrapped then
          self.bag_set("ui:" .. spec.key, wrapped, function(v) self:_on_control(rec, v) end)
        end
      end
    end
  end
  return created
end

function UI:_on_control(rec, v)
  if self.dead or self.syncing then return end
  local spec = rec.spec
  rec.last = v
  if spec.kind == "button" then
    if v == true or v == 1 then
      self:_apply(spec.key, true)
      self:_clear_button(rec)
    end
    return
  end
  self:_apply(spec.key, v)
end

function UI:_clear_button(rec)
  local prev = self.syncing
  self.syncing = true
  rec.last = false
  local el = self.elements[rec.spec.key]
  if el ~= nil then
    pcall(function() el:set_toggle(false) end)
    pcall(function() el:set_value(false) end)
  end
  self.host.set_flag(rec.flag, false)
  self.syncing = prev
end

-- Backup for hosts without change signals, and for sliders: read the bound flags.
function UI:_poll_flags()
  if self.dead or not self.bound then return end
  for i = 1, #self.bound do
    local rec = self.bound[i]
    local v = self.host.get_flag(rec.flag)
    if v ~= nil and v ~= rec.last then self:_on_control(rec, v) end
  end
end

-- Documented style.
function UI:_build_doc_menu()
  local host, juju = self.host, self.host.juju
  local caps = host.caps
  if not (caps.create_tab and caps.create_section) then return 0 end
  local created = 0
  local ok, err = pcall(function()
    juju.create_tab()
    if caps.set_tab_text then juju.set_tab_text("HitCheck") end
    local secs = {
      ["Hit Checker"] = juju.create_section("Hit Checker", 1, 1, 0),
      ["Auto Mode"] = juju.create_section("Auto Mode", 2, 1, 0),
    }
    if secs["Hit Checker"] == nil or secs["Auto Mode"] == nil then
      error("juju.create_section returned nil", 0)
    end
    local specs = self:_specs()
    for i = 1, #specs do
      local spec = specs[i]
      local info
      if spec.kind == "slider" then
        info = { name = spec.name, type = "slider", min = spec.min, max = spec.max }
      else
        info = { name = spec.name, type = "toggle" }
      end
      local el = self:_add(secs[spec.sec], info, function(v)
        if spec.kind == "button" then
          self:_apply(spec.key, true)
          self:_release(self.elements[spec.key])
        else
          self:_apply(spec.key, v)
        end
      end)
      if el ~= nil then
        created = created + 1
        self.elements[spec.key] = el
      end
    end
    self.syncing = true
    for i = 1, #specs do
      local spec = specs[i]
      if spec.kind ~= "button" then set_value(self.elements[spec.key], spec.default) end
    end
    self.syncing = false
  end)
  self.syncing = false
  if not ok then
    self.log("error", "building menu failed: " .. tostring(err))
  end
  return created
end

-- Flag-bound menus need a heartbeat of their own: the throttled refresh stops while tracking is
-- disabled, and without it a host that offers no change signals could never re-enable the addon.
function UI:start_menu_poll()
  if self.menu_style ~= "addon" or self.poll_on or self.dead then return end
  self.poll_on = true
  local period = self.cfg.ui_refresh * 4
  if period < 1 then period = 1 end
  local function tick()
    if self.dead or not self.poll_on then return end
    local ok, err = pcall(function() self:_poll_flags() end)
    if not ok then self.log("error", "menu poll: " .. tostring(err)) end
    local ok2, h = pcall(self.host.task.delay, period, tick)
    if ok2 then self.poll_handle = h else self.poll_on = false end
  end
  local ok, h = pcall(self.host.task.delay, period, tick)
  if ok then self.poll_handle = h else self.poll_on = false end
end

function UI:build_menu()
  self.syncing = true      -- ignore callbacks the host may fire while elements are created
  local created, why = self:_build_addon_menu()
  if created > 0 then
    self.menu_style = "addon"
  else
    if why then
      self.log("info", "addon-style create_element not accepted (" .. string.sub(tostring(why), 1, 80)
        .. "); trying the documented tab/section API")
    end
    self.elements = {}
    self.bound = {}
    created = self:_build_doc_menu()
    self.menu_style = (created > 0) and "documented" or "none"
  end
  self.syncing = false
  self.menu_ok = created > 0
  if not self.menu_ok then
    self.log("warn", "no menu controls could be created (is this loaded as a Juju addon? "
      .. "tracking, HUD and the console report still work)")
  else
    self.log("info", string.format("menu built: %d controls via the %s API", created, self.menu_style))
    self:start_menu_poll()
  end
  return self.menu_ok
end

-- ---------------------------------------------------------------------------------------
-- HUD (Drawing: executor standard, referenced by the on_unload doc example)
-- ---------------------------------------------------------------------------------------
function UI:_ensure_hud(n)
  if self.hud_failed or not self.host.caps.drawing then return false end
  self.hud = self.hud or {}
  local env = self.host.env
  local cfg = self.cfg
  while #self.hud < n do
    local i = #self.hud + 1
    local ok, obj = pcall(env.Drawing.new, "Text")
    if ok and obj ~= nil then
      local ok2, err2 = pcall(function()
        obj.Size = cfg.hud_size
        obj.Outline = true
        obj.Visible = false
        obj.Text = ""
        if env.Color3 and env.Color3.new then obj.Color = env.Color3.new(1, 1, 1) end
        if env.Vector2 and env.Vector2.new then
          obj.Position = env.Vector2.new(cfg.hud_x, cfg.hud_y + (i - 1) * (cfg.hud_size + 3))
        end
      end)
      if not ok2 then
        pcall(function() obj:Remove() end)        -- never leave a half-configured object on screen
        ok, obj = false, err2
      end
    end
    if not ok or obj == nil then
      self.hud_failed = true
      self.log("warn", "Drawing HUD unavailable: " .. tostring(obj))
      return false
    end
    self.hud[i] = { obj = obj, text = "" }
  end
  return true
end

function UI:apply_hud()
  if self.hud then
    for i = 1, #self.hud do
      pcall(function() self.hud[i].obj.Visible = self.cfg.hud end)
    end
  end
end

function UI:render_hud()
  if not self.cfg.hud then return end
  local lines = self:lines()
  if not self:_ensure_hud(#lines) then return end
  for i = 1, #lines do
    local h = self.hud[i]
    if h.text ~= lines[i] then
      h.text = lines[i]
      pcall(function() h.obj.Text = lines[i] end)
    end
    pcall(function() h.obj.Visible = true end)
  end
end

-- ---------------------------------------------------------------------------------------
-- Flags / tab text / flush
-- ---------------------------------------------------------------------------------------
function UI:export_flags()
  local s = self.engine:stats("all")
  local vals = {
    jhc_version = Config.VERSION, jhc_shots = s.attempted, jhc_hits = s.hits, jhc_misses = s.misses,
    jhc_unconfirmed = s.unconfirmed, jhc_not_fired = s.not_fired,
    jhc_hit_pct = s.hit_pct and math.floor(s.hit_pct * 10 + 0.5) / 10 or -1,
    jhc_auto_state = self.auto.state, jhc_weapon = self:weapon_label(),
  }
  for name, v in pairs(vals) do
    if self.flag_cache[name] ~= v then
      self.flag_cache[name] = v
      if self.host.set_flag(name, v) then self.flag_writes = self.flag_writes + 1 end
    end
  end
end

function UI:update_tab_text()
  if not self.host.caps.set_tab_text or not self.menu_ok then return end
  local want
  if self.cfg.tab_summary or self.hud_failed or not self.host.caps.drawing or not self.cfg.hud then
    want = self:tab_text()
  else
    want = "HitCheck"
  end
  if want ~= self.tab_text_cache then
    self.tab_text_cache = want
    pcall(self.host.juju.set_tab_text, want)
  end
end

function UI:flush()
  if self.dead or not self.dirty then return end
  self.dirty = false
  self.last_render = self.host.clock()
  self.renders = self.renders + 1
  local ok, err = pcall(function()
    self:_poll_flags()        -- menu controls bound to flags (addon-style hosts)
    self:render_hud()
    self:export_flags()
    self:update_tab_text()
  end)
  if not ok then self.log("error", "ui flush: " .. tostring(err)) end
end

function UI:mark_dirty()
  if self.dead then return end
  self.dirty = true
  if self.scheduled then return end
  self.scheduled = true
  local wait = self.cfg.ui_refresh - (self.host.clock() - self.last_render)
  if wait < 0 then wait = 0 end
  local ok, handle = pcall(self.host.task.delay, wait, function()
    self.scheduled = false
    self.flush_handle = nil
    self:flush()
  end)
  if ok then
    self.flush_handle = handle
  else
    self.scheduled = false
    self.log("error", "ui: could not schedule refresh")
  end
end

function UI:destroy()
  self.dead = true
  self.poll_on = false
  if self.poll_handle ~= nil and self.host.caps.task_cancel then
    pcall(self.host.task.cancel, self.poll_handle)
  end
  self.poll_handle = nil
  if self.flush_handle ~= nil and self.host.caps.task_cancel then
    pcall(self.host.task.cancel, self.flush_handle)
  end
  self.flush_handle = nil
  if self.hud then
    for i = 1, #self.hud do
      pcall(function() self.hud[i].obj:Remove() end)
    end
    self.hud = nil
  end
end

return UI
