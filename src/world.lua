-- world.lua
-- Roblox glue. Translates engine-level events from standard Roblox instances/signals:
--   Tool.Activated on the equipped Tool        -> shot attempt
--   Humanoid.HealthChanged / Died (other players) -> server-replicated damage
--   numeric ammo-like child value / attribute  -> optional "weapon fired" evidence
--   Player.CharacterAdded/Removing, Character.ChildAdded/Removed -> context (respawn, equip)
-- These are standard Roblox APIs, NOT part of the Juju docs (see docs/API_REFERENCE.md section 3).
-- Every connection goes through the Bag (keyed -> no duplicates, one place to clean up).

local U = require("util")
local Weapon = require("weapon")

local W = {}
W.__index = W

local function uid_of(player)
  local ok, id = pcall(function() return player.UserId end)
  if ok and id ~= nil then return id end
  local ok2, name = pcall(function() return player.Name end)
  if ok2 then return name end
  return nil
end

-- ctx: host, cfg, engine, diag, auto, bag, log, ui_dirty()
function W.new(ctx)
  local self = setmetatable({}, W)
  self.host = ctx.host
  self.cfg = ctx.cfg
  self.engine = ctx.engine
  self.diag = ctx.diag
  self.auto = ctx.auto
  self.bag = ctx.bag
  self.log = ctx.log or function() end
  self.dirty = ctx.ui_dirty or function() end
  self.lp = nil
  self.char = nil
  self.current = nil       -- { tool, weapon, ammo_kind, ammo_last }
  self.targets = {}        -- uid -> { player, hum, last }
  self.sampler_gen = 0
  self.sampler_on = false
  self.started = false
  self.counts = { shots_seen = 0, shot_errors = 0, bullets_seen = 0 }
  return self
end

-- ---------------------------------------------------------------------------------------
-- Lifecycle
-- ---------------------------------------------------------------------------------------
function W:start()
  if self.started then return end
  self.started = true
  local host = self.host
  self.lp = host.local_player()
  local lp = self.lp
  if lp == nil then
    self.log("warn", "LocalPlayer not available: shot tracking disabled")
  else
    self.bag:set("lp:added", lp.CharacterAdded, function(c) self:_on_local_char(c) end)
    self.bag:set("lp:removing", lp.CharacterRemoving, function(c) self:_on_local_removing(c) end)
    if lp.Character then self:_on_local_char(lp.Character) end
  end
  self:_hook_juju_signals()
  local pl = host.players
  self.bag:set("pl:added", pl.PlayerAdded, function(p) self:_track_player(p) end)
  self.bag:set("pl:removing", pl.PlayerRemoving, function(p) self:_untrack_player(p) end)
  local ok, list = pcall(function() return pl:GetPlayers() end)
  if ok and type(list) == "table" then
    for i = 1, #list do self:_track_player(list[i]) end
  end
end

-- Juju's own bullet-confirmation signal, if this Juju build has it (found by name at runtime).
function W:_hook_juju_signals()
  self.juju_confirm_hooked = false
  if not self.cfg.use_juju_signals then return end
  local sig = self.host.juju_signal("on_local_bullet_confirmed")
  if sig ~= nil then
    local ok = self.bag:set("juju:confirmed", sig, function(player, part, dmg)
      self:_on_juju_confirmed(player, part, dmg)
    end)
    self.juju_confirm_hooked = ok ~= nil
  end
  self:_hook_bullet_signal()
end

-- Shot attempts for guns. Hood Customs guns do not fire Tool.Activated; this signal does, once per
-- bullet, and each client only receives its own bullets (verified with two clients).
function W:_hook_bullet_signal()
  self.bullet_hooked = false
  if not self.cfg.use_bullet_signal then return end
  local sig = self.host.juju_signal("on_player_bullet_fired")
  if sig == nil then return end
  local ok = self.bag:set("juju:fired", sig, function() self:_on_bullet_fired() end)
  self.bullet_hooked = ok ~= nil
end

function W:_on_bullet_fired()
  if not self.cfg.enabled then return end
  local cur = self.current
  if cur == nil then return end                      -- weapon unknown: do not invent a shot
  local t = self.host.clock()
  self.counts.bullets_seen = self.counts.bullets_seen + 1
  if self.engine:add_pellet(t, cur.weapon.key) then return end   -- same trigger pull
  self:_begin_shot(t, cur, "bullet")
end

function W:_on_juju_confirmed(player, part, dmg)
  if not self.cfg.enabled then return end
  local uid = (player ~= nil) and uid_of(player) or nil
  if uid == nil then
    self.engine.counters.invalid_events = self.engine.counters.invalid_events + 1
    return
  end
  local amount = tonumber(dmg)
  if amount ~= nil and U.is_finite(amount) then amount = math.abs(amount) else amount = nil end
  self.engine:register_confirm({ uid = uid, amount = amount })
  self.dirty()
end

function W:stop()
  self:stop_sampler()
  self.bag:clear()
  U.clear(self.targets)
  self.current = nil
  self.char = nil
  self.started = false
end

-- ---------------------------------------------------------------------------------------
-- Background sampler (one task, 1 wake per cfg.diag_interval, only while enabled)
-- ---------------------------------------------------------------------------------------
function W:start_sampler()
  if self.sampler_on then return end
  local host = self.host
  if not host.caps.task_wait then return end
  self.sampler_on = true
  self.sampler_gen = self.sampler_gen + 1
  local gen = self.sampler_gen
  local ok, thread = pcall(host.task.spawn, function()
    local first = true
    while self.sampler_on and gen == self.sampler_gen do
      local c0 = host.clock()
      local waited = host.task.wait(self.cfg.diag_interval)
      if first then
        first = false
        self:_check_clock(c0, waited)
      end
      if not (self.sampler_on and gen == self.sampler_gen) then break end
      local ok2, err = pcall(function() self:_sample_tick() end)
      if not ok2 then self.log("error", "sampler: " .. tostring(err)) end
    end
  end)
  if not ok then
    -- never leave the flag set when no sampler exists
    self.sampler_on = false
    self.sampler_gen = self.sampler_gen + 1
    error("sampler could not start: " .. tostring(thread), 0)
  end
  self.sampler_thread = thread
end

-- One-time sanity check of the clock the timing logic relies on: the time os.clock() advanced
-- during task.wait(n) must be about what task.wait reports. If not (e.g. a CPU-time clock), every
-- timing-based verdict is suspect and the report says so.
function W:_check_clock(c0, waited)
  local dt = self.host.clock() - c0
  if type(waited) == "number" and waited > 0 and (dt < waited * 0.5 or dt > waited * 2) then
    self.host.clock_suspect = true
    self.log("warn", string.format("clock mismatch: task.wait reported %.3fs but the clock advanced %.3fs - "
      .. "timing diagnostics are unreliable", waited, dt))
  end
end

function W:stop_sampler()
  self.sampler_on = false
  self.sampler_gen = self.sampler_gen + 1
  if self.sampler_thread ~= nil and self.host.caps.task_cancel then
    pcall(self.host.task.cancel, self.sampler_thread)
  end
  self.sampler_thread = nil
end

function W:_sample_tick()
  self.diag:sample("bg", true)
  self.diag:sample_gap()
  self:refresh_host_auto()
  self.auto:update({ degraded = self.diag:degraded_now() })
  self.dirty()
end

-- Looks for Juju's own auto flag: exact name if configured, else a name heuristic over
-- juju.get_flags() (names are NOT documented, so the result is "unknown" when nothing matches).
function W:refresh_host_auto()
  local host, cfg = self.host, self.cfg
  local name = cfg.host_auto_flag
  if name == nil or name == "" then
    if self.host_flag_name == nil then
      -- rescan at most every 30 ticks: get_flags() is a host call and the flag may appear later
      self.scan_wait = (self.scan_wait or 0) - 1
      if self.scan_wait <= 0 then
        self.scan_wait = 30
        local flags = host.flag_names()
        for i = 1, #flags do
          local n = U.normalize_name(tostring(flags[i]))
          if string.find(n, "automode", 1, true) or n == "auto" then
            self.host_flag_name = flags[i]
            break
          end
        end
      end
    end
    name = self.host_flag_name
  end
  if name == nil or name == "" then
    self.auto:update({ host_auto = nil })
    return
  end
  local v = host.get_flag(name)
  if v == nil then
    self.auto:update({ host_auto = nil })
  else
    self.auto:update({ host_auto = (v and v ~= 0) and true or false })
  end
end

-- ---------------------------------------------------------------------------------------
-- Local player: character, tool
-- ---------------------------------------------------------------------------------------
function W:_on_local_char(char)
  self.bag:drop_prefix("char:")
  self.bag:drop_prefix("tool:")
  self.current = nil
  self.char = char
  self.auto:update({ char_alive = true, weapon_is_dbs = false })
  local bag = self.bag
  bag:set("char:added", char.ChildAdded, function(c)
    self:_maybe_equip(c)
    self:_maybe_local_humanoid(c)
  end)
  bag:set("char:removed", char.ChildRemoved, function(c) self:_maybe_unequip(c) end)
  local ok, hum = pcall(function() return char:FindFirstChildOfClass("Humanoid") end)
  if ok and hum then
    bag:set("char:died", hum.Died, function() self:_on_local_died() end)
  end
  local ok2, kids = pcall(function() return char:GetChildren() end)
  if ok2 and type(kids) == "table" then
    for i = 1, #kids do self:_maybe_equip(kids[i]) end
  end
  self.dirty()
end

-- The local Humanoid can replicate after the Character model: hook Died when it shows up.
function W:_maybe_local_humanoid(inst)
  local ok, isHum = pcall(function() return inst:IsA("Humanoid") end)
  if ok and isHum then
    self.bag:set("char:died", inst.Died, function() self:_on_local_died() end)
  end
end

function W:_on_local_died()
  self.engine:note_context("died")
  self.auto:update({ char_alive = false })
  self.dirty()
end

function W:_on_local_removing()
  self.engine:note_context("respawn")
  self.bag:drop_prefix("char:")
  self.bag:drop_prefix("tool:")
  self.current = nil
  self.char = nil
  self.auto:update({ char_alive = false, weapon_is_dbs = false })
  self.dirty()
end

local function is_tool(inst)
  local ok, r = pcall(function() return inst:IsA("Tool") end)
  return ok and r == true
end

function W:_maybe_equip(inst)
  if not is_tool(inst) then return end
  if self.current and self.current.tool == inst then return end   -- duplicate ChildAdded
  if self.current then
    self.engine:note_weapon_switch()
    self.bag:drop_prefix("tool:")
    self.current = nil
  end
  self:_set_weapon(inst)
end

function W:_maybe_unequip(inst)
  if not (self.current and self.current.tool == inst) then return end
  self.engine:note_weapon_switch()
  self.bag:drop_prefix("tool:")
  self.current = nil
  self.auto:update({ weapon_is_dbs = false })
  self.dirty()
end

function W:_set_weapon(tool)
  local nameok, name = pcall(function() return tool.Name end)
  local weapon = Weapon.identify(nameok and name or nil, self.cfg)
  local cur = { tool = tool, weapon = weapon }
  self.current = cur
  self.bag:set("tool:activated", tool.Activated, function() self:_on_activated(tool) end)
  self:_find_ammo(cur)
  self.auto:update({ weapon_is_dbs = weapon.is_dbs })
  self.log("info", string.format("equipped %s (key=%s dbs=%s ammo=%s)", weapon.name, weapon.key,
    tostring(weapon.is_dbs), cur.ammo_kind or "none"))
  self.dirty()
end

-- Optional "weapon fired" evidence: first numeric ammo-like value child or attribute.
function W:_find_ammo(cur)
  local tool, cfg = cur.tool, self.cfg
  local ok, kids = pcall(function() return tool:GetChildren() end)
  if ok and type(kids) == "table" then
    for i = 1, #kids do
      local k = kids[i]
      local isnum = false
      pcall(function() isnum = k:IsA("IntValue") or k:IsA("NumberValue") end)
      if isnum and Weapon.is_ammo_name(k.Name, cfg) then
        cur.ammo_kind = "value:" .. tostring(k.Name)
        cur.ammo_validated = false
        cur.ammo_last = k.Value
        self.bag:set("tool:ammo", k.Changed, function(v) self:_on_ammo(tool, v) end)
        return
      end
    end
  end
  local ok2, attrs = pcall(function() return tool:GetAttributes() end)
  if ok2 and type(attrs) == "table" then
    for name, val in pairs(attrs) do
      if type(val) == "number" and Weapon.is_ammo_name(name, cfg) then
        cur.ammo_kind = "attr:" .. tostring(name)
        cur.ammo_validated = false
        cur.ammo_last = val
        self.bag:set("tool:ammo", tool:GetAttributeChangedSignal(name), function()
          self:_on_ammo(tool, tool:GetAttribute(name))
        end)
        return
      end
    end
  end
end

function W:_on_ammo(tool, v)
  local cur = self.current
  if not cur or cur.tool ~= tool or not self.cfg.enabled then return end
  if not U.is_finite(v) then return end
  local last = cur.ammo_last
  cur.ammo_last = v
  if last ~= nil and v < last then
    cur.ammo_validated = true      -- it really drops: from now on its silence means "did not fire"
    self.engine:register_fire({ t = self.host.clock(), weapon_key = cur.weapon.key })
  elseif last ~= nil and v > last then
    self.log("debug", "reload detected (" .. tostring(cur.ammo_kind) .. ")")
  end
end

function W:_on_activated(tool)
  local cur = self.current
  if not cur or cur.tool ~= tool or not self.cfg.enabled then return end
  self.counts.shots_seen = self.counts.shots_seen + 1
  local host = self.host
  local t = host.clock()
  -- the name may carry changing text (ammo counters): identify again, key ignores digits
  local ok, nm = pcall(function() return tool.Name end)
  if ok then
    local w = Weapon.identify(nm, self.cfg)
    if w.key ~= cur.weapon.key or w.is_dbs ~= cur.weapon.is_dbs then
      cur.weapon = w
      self.auto:update({ weapon_is_dbs = w.is_dbs })
    end
  end
  self:_begin_shot(t, cur, "activated")
end

function W:_begin_shot(t, cur, source)
  local ping = self.diag:sample("shot", false)
  local gap = self.diag:sample_gap()
  local cand, n = self:_candidates()
  self.engine:register_shot({
    t = t, weapon = cur.weapon, mode = self.auto:mode_tag(), candidates = cand, ncand = n,
    ping_ms = ping, gap = gap, ammo_tracked = (cur.ammo_kind ~= nil and cur.ammo_validated == true),
    source = source, pellets = (source == "bullet") and 1 or 0,
  })
  self.dirty()
end

-- Snapshot of players whose damage could confirm this shot (only players we actually observe).
function W:_candidates()
  local scope = self.cfg.scope
  local set, n = {}, 0
  local rt = nil
  if scope ~= "all" then rt = self.host.ragebot_target() end
  if scope == "target" or (scope == "auto" and rt ~= nil) then
    if rt ~= nil then
      local uid = uid_of(rt)
      local tg = uid ~= nil and self.targets[uid] or nil
      if tg and tg.hum then
        set[uid] = true
        n = 1
      end
    end
    return set, n
  end
  for uid, tg in pairs(self.targets) do
    if tg.hum then
      set[uid] = true
      n = n + 1
    end
  end
  return set, n
end

-- ---------------------------------------------------------------------------------------
-- Other players: Humanoid health
-- ---------------------------------------------------------------------------------------
function W:_track_player(p)
  if p == self.lp then return end
  local uid = uid_of(p)
  if uid == nil or self.targets[uid] then return end
  self.targets[uid] = { player = p, hum = nil, last = nil }
  local bag = self.bag
  local key = "t:" .. tostring(uid) .. ":"
  bag:set(key .. "added", p.CharacterAdded, function(c) self:_hook_target(uid, c) end)
  bag:set(key .. "removing", p.CharacterRemoving, function() self:_unhook_target(uid) end)
  local ok, c = pcall(function() return p.Character end)
  if ok and c then self:_hook_target(uid, c) end
end

function W:_hook_target(uid, char)
  local tg = self.targets[uid]
  if not tg then return end
  local key = "t:" .. tostring(uid) .. ":"
  self.bag:drop_prefix(key .. "h")
  tg.hum, tg.last = nil, nil
  local ok, hum = pcall(function() return char:FindFirstChildOfClass("Humanoid") end)
  if ok and hum then
    self:_bind_humanoid(uid, hum)
  else
    -- Humanoid may arrive after the character model
    self.bag:set(key .. "hwait", char.ChildAdded, function(c)
      local isHum = false
      pcall(function() isHum = c:IsA("Humanoid") end)
      if isHum then
        self.bag:drop(key .. "hwait")
        self:_bind_humanoid(uid, c)
      end
    end)
  end
end

function W:_bind_humanoid(uid, hum)
  local tg = self.targets[uid]
  if not tg then return end
  local key = "t:" .. tostring(uid) .. ":"
  tg.hum = hum
  local okh, h = pcall(function() return hum.Health end)
  tg.last = okh and h or nil
  self.bag:set(key .. "hp", hum.HealthChanged, function(health) self:_on_health(uid, health) end)
  -- every Humanoid-scoped key starts with "h" so drop_prefix(key .. "h") releases them all
  self.bag:set(key .. "hdied", hum.Died, function() self:_on_target_died(uid) end)
end

function W:_on_health(uid, health)
  local tg = self.targets[uid]
  if not tg or type(health) ~= "number" or health ~= health then return end
  local last = tg.last
  tg.last = health
  if last ~= nil and health < last and self.cfg.enabled then
    self.engine:register_damage({ uid = uid, amount = last - health })
  end
end

function W:_on_target_died(uid)
  local tg = self.targets[uid]
  if not tg then return end
  local last = tg.last
  if last ~= nil and last > 0 and self.cfg.enabled then
    tg.last = 0
    self.engine:register_damage({ uid = uid, amount = last })
  end
end

function W:_unhook_target(uid)
  local tg = self.targets[uid]
  if not tg then return end
  self.bag:drop_prefix("t:" .. tostring(uid) .. ":h")
  tg.hum, tg.last = nil, nil
  self.engine:target_lost(uid)
end

function W:_untrack_player(p)
  local uid = uid_of(p)
  if uid == nil or not self.targets[uid] then return end
  self.bag:drop_prefix("t:" .. tostring(uid) .. ":")
  self.targets[uid] = nil
  self.engine:target_lost(uid)
end

function W:target_count()
  return U.count(self.targets)
end

return W
