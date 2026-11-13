-- engine.lua
-- Hit Checker core. Pure logic: no Roblox/Juju access. Time and timers are injected, so the
-- same code runs under a virtual clock in tests and under task.delay in the game.
--
-- Every shot attempt ends in exactly ONE outcome:
--   hit          replicated damage on an observable candidate, inside the window, not earlier
--                than the causal floor (causal_ratio * ping at shot time)
--   miss         window elapsed, nothing observed, >=1 observable candidate, healthy connection,
--                no context change, no overlap ambiguity, firing not disproved
--   unconfirmed  cannot be told (degraded connection, stall, respawn / weapon change mid-window,
--                target lost, nothing observable, ambiguous overlapping shot, late damage)
--   not_fired    a VALIDATED ammo source (one that has been seen to drop on a shot) shows no
--                decrement: cooldown / empty gun. Damage seen on such a shot is not credited to it.
-- Invariant: attempted = hit + miss + unconfirmed + not_fired + pending.
--
-- A hit is only ever produced by observed damage. Absence of damage never becomes a hit.

local U = require("util")

local E = {}
E.__index = E

local ZERO = 1e-9

local function new_bucket()
  return {
    attempted = 0, hits = 0, misses = 0, unconfirmed = 0, not_fired = 0, deduped = 0,
    fired = 0, damage = 0, lat_sum = 0, lat_n = 0, lat_min = nil, lat_max = nil,
    ratio_sum = 0, ratio_n = 0,   -- hit latency / ping at shot time (calibration aid)
    confirmed_hits = 0,           -- hits also confirmed by Juju's own on_local_bullet_confirmed
  }
end

local function is_cand(shot, uid)
  return shot.cand[uid] and not (shot.lost and shot.lost[uid])
end

-- deps: cfg (values table), now() -> seconds, timers { delay(sec, fn) -> handle, cancel(handle) },
--       diag (window / degraded_between / note_latency), log(level, msg), on_change()
function E.new(deps)
  local self = setmetatable({}, E)
  self.cfg = deps.cfg
  self.now = deps.now
  self.timers = deps.timers
  self.diag = deps.diag
  self.log = deps.log or function() end
  self.on_change = deps.on_change or function() end
  self.dead = false
  self.seq = 0
  self:_init_state()
  return self
end

function E:_init_state()
  self.pending = {}                 -- FIFO of unresolved shots
  self.by_id = {}
  self.buckets = { all = new_bucket() }
  self.counters = {
    late_damage = 0, early_damage = 0, unattributed_damage = 0, fires_matched = 0,
    fire_unmatched = 0, invalid_events = 0, clock_anomaly = 0, timer_failures = 0,
    weapon_switches = 0, shots_spanning_switch = 0,
    juju_confirms = 0, corroborated = 0, confirm_pellets = 0, confirm_unmatched = 0,
  }
  self.reasons = {}                 -- unconfirmed reason -> count
  self.bursts = {}                  -- uid -> open damage burst
  self.recent_miss = U.Ring.new(16) -- recently resolved misses (for late-damage detection)
  self.recent_hit = U.Ring.new(16)  -- recently resolved hits (for Juju confirmation matching)
  self.cbursts = {}                 -- uid -> last Juju confirmation (pellet de-duplication)
  self.events = U.Ring.new(self.cfg.log_size)
  self.last_attempt = {}            -- weapon key -> time of last accepted attempt
  self.intervals = {}               -- weapon key -> Ring of inter-shot intervals
  self.pre_fire = {}                -- weapon key -> time of an ammo decrement seen before its shot
  self.last_shot = nil
end

function E:_bucket(name)
  local b = self.buckets[name]
  if not b then
    b = new_bucket()
    self.buckets[name] = b
  end
  return b
end

function E:_apply(shot, field, delta)
  local list = shot.b
  for i = 1, #list do
    list[i][field] = list[i][field] + delta
  end
end

function E:_event(t, kind, text)
  self.events:push({ t = t, kind = kind, text = text })
  self.log("debug", kind .. ": " .. text)
end

-- ---------------------------------------------------------------------------------------
-- Shots
-- ---------------------------------------------------------------------------------------
-- info: { t?, weapon={key,name,is_dbs}, mode="auto"|"manual", candidates={uid=true},
--         ncand?, ping_ms?, gap?, ammo_tracked? }
function E:register_shot(info)
  if self.dead then return nil, "dead" end
  local cfg = self.cfg
  local t = info.t or self.now()
  local weapon = info.weapon or { key = "unknown", name = "?", is_dbs = false }
  local mode = (info.mode == "auto") and "auto" or "manual"
  local bnames = { "all", "mode:" .. mode, "weapon:" .. weapon.key }
  local blist = {}
  for i = 1, #bnames do blist[i] = self:_bucket(bnames[i]) end

  local last = self.last_attempt[weapon.key]
  if last ~= nil and t < last then
    self.counters.clock_anomaly = self.counters.clock_anomaly + 1
    t = last
  end
  if last ~= nil and (t - last) < cfg.dedupe_eps then
    for i = 1, #blist do blist[i].deduped = blist[i].deduped + 1 end
    self:_event(t, "dedupe", weapon.key .. " duplicate attempt")
    return nil, "deduped"
  end
  if last ~= nil then
    local ring = self.intervals[weapon.key]
    if not ring then
      ring = U.Ring.new(32)
      self.intervals[weapon.key] = ring
    end
    ring:push(t - last)
  end
  self.last_attempt[weapon.key] = t

  local window = nil
  local okw, w = pcall(self.diag.window, self.diag)
  if okw and U.is_finite(w) and w > 0 then
    window = w
  else
    window = U.clamp(cfg.window_default, cfg.window_min, cfg.window_max)
  end

  local cand = {}
  local n = 0
  if type(info.candidates) == "table" then
    for uid, v in pairs(info.candidates) do
      if v then
        cand[uid] = true
        n = n + 1
      end
    end
  end

  self.seq = self.seq + 1
  local shot = {
    id = self.seq, t = t, window = window, deadline = t + window,
    weapon = weapon, mode = mode, cand = cand, ncand = n, nlive = n,
    ping = info.ping_ms, gap = info.gap, ammo_tracked = info.ammo_tracked and true or false,
    state = "pending", b = blist, overlap = false, overlap_hit = false,
    damage_total = 0, damage_events = 0, source = info.source or "activated", pellets = info.pellets or 0,
  }

  -- Ammo decrement that arrived a hair before the activation (handler order inside one frame).
  local pf = self.pre_fire[weapon.key]
  if pf ~= nil and (t - pf) >= 0 and (t - pf) <= cfg.same_frame_eps then
    shot.fire = true
    self.pre_fire[weapon.key] = nil
    self.counters.fires_matched = self.counters.fires_matched + 1
  end

  for i = 1, #blist do blist[i].attempted = blist[i].attempted + 1 end
  if shot.fire then self:_apply(shot, "fired", 1) end

  for i = 1, #self.pending do
    local o = self.pending[i]
    if o.deadline > t then
      o.overlap = true
      shot.overlap = true
    end
  end

  self.pending[#self.pending + 1] = shot
  self.by_id[shot.id] = shot
  self.last_shot = shot

  local id = shot.id
  local okt, handle = pcall(self.timers.delay, window, function() self:_on_timer(id) end)
  if okt then
    shot.timer = handle
  else
    self.counters.timer_failures = self.counters.timer_failures + 1
    self:_finish(shot, "unconfirmed", "timer_unavailable", t)
    return shot
  end

  self:_event(t, "shot", string.format("#%d %s via=%s mode=%s cand=%d window=%.0fms ping=%s",
    shot.id, weapon.key, shot.source, mode, n, window * 1000,
    shot.ping and string.format("%.0f", shot.ping) or "n/a"))
  self.on_change()
  return shot
end

function E:_on_timer(id)
  local shot = self.by_id[id]
  if not shot or self.dead then return end
  local t = self.now()
  if t < shot.deadline - 1e-6 then
    -- fired early: wait for the remainder
    local ok, handle = pcall(self.timers.delay, shot.deadline - t, function() self:_on_timer(id) end)
    if ok then
      shot.timer = handle
    else
      self.counters.timer_failures = self.counters.timer_failures + 1
      self:_finish(shot, "unconfirmed", "timer_unavailable", t)
    end
    return
  end
  shot.timer = nil
  self:_expire(shot, t)
end

function E:_expire(shot, t)
  local cfg = self.cfg
  local outcome, reason
  if shot.ncand == 0 then
    outcome, reason = "unconfirmed", "no_observable_target"
  elseif shot.nlive <= 0 then
    outcome, reason = "unconfirmed", "target_lost"
  elseif cfg.causal_check and shot.ping and shot.window <= (shot.ping / 1000) * cfg.causal_ratio then
    -- misconfigured: no damage could ever be accepted inside this window
    outcome, reason = "unconfirmed", "window_below_causal_floor"
  elseif shot.ctx then
    outcome, reason = "unconfirmed", shot.ctx
  else
    local degraded, why = false, nil
    pcall(self.diag.sample, self.diag, "expiry", false)       -- a spike that began mid-window shows up now
    local ok, d, w = pcall(self.diag.degraded_between, self.diag, shot.t, math.max(shot.deadline, t))
    if ok and d then degraded, why = true, w end
    if not degraded and (t - shot.deadline) > cfg.timer_late_tol then
      degraded, why = true, "stall"
    end
    if degraded then
      outcome, reason = "unconfirmed", "degraded:" .. tostring(why)
    elseif shot.deferred then
      outcome, reason = "not_fired", "damage_without_fire"
    elseif shot.overlap_hit then
      outcome, reason = "unconfirmed", "ambiguous_overlap"
    elseif shot.late_damage then
      outcome, reason = "unconfirmed", "late_damage"
    elseif shot.ammo_tracked and not shot.fire and not shot.weapon_switched then
      outcome, reason = "not_fired", "no_ammo_change"
    else
      outcome = "miss"
    end
  end
  self:_finish(shot, outcome, reason, t)
end

function E:_finish(shot, outcome, reason, t)
  if shot.state ~= "pending" then return end
  for i = 1, #self.pending do
    if self.pending[i] == shot then
      table.remove(self.pending, i)
      break
    end
  end
  self.by_id[shot.id] = nil
  if shot.timer ~= nil then
    pcall(self.timers.cancel, shot.timer)
    shot.timer = nil
  end
  shot.state = "resolved"
  shot.outcome = outcome
  shot.reason = reason
  shot.done_t = t

  if outcome == "hit" then
    self:_apply(shot, "hits", 1)
    self:_apply(shot, "damage", shot.damage_total)
    local lat = shot.latency
    local list = shot.b
    for i = 1, #list do
      local b = list[i]
      b.lat_sum = b.lat_sum + lat
      b.lat_n = b.lat_n + 1
      if b.lat_min == nil or lat < b.lat_min then b.lat_min = lat end
      if b.lat_max == nil or lat > b.lat_max then b.lat_max = lat end
      if shot.ping and shot.ping > 0 then
        b.ratio_sum = b.ratio_sum + lat / (shot.ping / 1000)
        b.ratio_n = b.ratio_n + 1
      end
    end
    pcall(self.diag.note_latency, self.diag, lat, shot.juju_confirmed == true)
    self.recent_hit:push(shot)
    self:_event(t, "hit", string.format("#%d %s latency=%.0fms dmg=%.1f", shot.id, shot.weapon.key,
      lat * 1000, shot.damage_total))
  elseif outcome == "miss" then
    self:_apply(shot, "misses", 1)
    self.recent_miss:push(shot)
    self:_event(t, "miss", string.format("#%d %s", shot.id, shot.weapon.key))
  elseif outcome == "not_fired" then
    self:_apply(shot, "not_fired", 1)
    self:_event(t, "not_fired", string.format("#%d %s (%s)", shot.id, shot.weapon.key, tostring(reason)))
  else
    self:_apply(shot, "unconfirmed", 1)
    local key = tostring(reason)
    self.reasons[key] = (self.reasons[key] or 0) + 1
    self:_event(t, "unconfirmed", string.format("#%d %s (%s)", shot.id, shot.weapon.key, key))
  end
  self.on_change()
end

-- ---------------------------------------------------------------------------------------
-- Damage
-- ---------------------------------------------------------------------------------------
-- true if a pending shot registered after `since` could own damage on `uid` arriving at `t`
function E:_newer_shot(uid, since, t)
  for i = 1, #self.pending do
    local s = self.pending[i]
    if s.t > since and not s.burst and is_cand(s, uid) and t >= s.t and t <= s.deadline + ZERO then
      return true
    end
  end
  return false
end

-- info: { t?, uid, amount }   amount > 0 = health lost by that player (server-replicated)
function E:register_damage(info)
  if self.dead then return "dead" end
  local cfg = self.cfg
  local uid, amount = info.uid, info.amount
  if uid == nil or not U.is_finite(amount) or amount <= 0 then
    self.counters.invalid_events = self.counters.invalid_events + 1
    return "invalid"
  end
  local t = info.t or self.now()

  -- Same burst (pellets of one shot arrive together)? A burst is bounded in length and can never
  -- swallow damage that a shot registered AFTER the burst began could own.
  local b = self.bursts[uid]
  if b and t >= b.last and (t - b.last) <= cfg.burst_gap and (t - b.first) <= cfg.burst_gap * 3
     and not self:_newer_shot(uid, b.first, t) then
    b.last = t
    b.events = b.events + 1
    b.damage = b.damage + amount
    local s = b.shot
    if s then
      s.damage_total = s.damage_total + amount
      s.damage_events = s.damage_events + 1
      if s.state == "resolved" and s.outcome == "hit" then self:_apply(s, "damage", amount) end
    end
    return "burst"
  end

  -- Oldest pending shot that could have caused it.
  local chosen, early, late_pending = nil, false, nil
  for i = 1, #self.pending do
    local s = self.pending[i]
    if not s.burst and is_cand(s, uid) and t >= s.t then
      if t <= s.deadline + ZERO then
        local floor = 0
        if cfg.causal_check and s.ping then floor = (s.ping / 1000) * cfg.causal_ratio end
        if (t - s.t) < floor then
          early = true
        else
          chosen = s
        end
        break
      elseif late_pending == nil and (t - s.deadline) <= cfg.late_grace * s.window then
        late_pending = s     -- window closed but its expiry timer has not run yet
      end
    end
  end

  if chosen then
    local burst = { first = t, last = t, events = 1, damage = amount, shot = chosen }
    self.bursts[uid] = burst
    chosen.burst = burst
    chosen.victim = uid
    chosen.damage_total = amount
    chosen.damage_events = 1
    chosen.hit_t = t
    chosen.latency = t - chosen.t
    -- later overlapping shots can no longer be told apart from this damage
    for i = 1, #self.pending do
      local o = self.pending[i]
      if o ~= chosen and not o.burst and is_cand(o, uid) and t >= o.t and t <= o.deadline + ZERO then
        o.overlap_hit = true
      end
    end
    if chosen.ammo_tracked and not chosen.fire then
      -- the weapon shows no sign of having fired: wait for the ammo evidence (it can lag by up
      -- to a round trip); if none comes before the deadline the damage was someone else's
      chosen.deferred = true
      return "deferred"
    end
    self:_finish(chosen, "hit", nil, t)
    return "hit"
  end

  if early then
    self.counters.early_damage = self.counters.early_damage + 1
    self.bursts[uid] = { first = t, last = t, events = 1, damage = amount, shot = nil }
    self:_event(t, "early_damage", string.format("uid=%s %.1f dmg before causal floor: not attributed",
      tostring(uid), amount))
    return "early"
  end

  if late_pending then
    late_pending.late_damage = true
    self.counters.late_damage = self.counters.late_damage + 1
    pcall(self.diag.note_latency, self.diag, t - late_pending.t)
    self.bursts[uid] = { first = t, last = t, events = 1, damage = amount, shot = nil }
    self:_event(t, "late_damage", string.format("#%d damage after its window closed (expiry not run yet)",
      late_pending.id))
    return "late"
  end

  -- Damage shortly after a declared miss (within late_grace * window)? Then the miss was premature.
  for i = self.recent_miss:size(), 1, -1 do
    local m = self.recent_miss:get(i)
    if m.outcome == "miss" and m.cand[uid] and not (m.lost and m.lost[uid]) and t >= m.t
       and t >= m.deadline and (t - m.deadline) <= cfg.late_grace * m.window then
      self:_apply(m, "misses", -1)
      self:_apply(m, "unconfirmed", 1)
      m.outcome = "unconfirmed"
      m.reason = "late_damage"
      m.late_latency = t - m.t
      self.reasons.late_damage = (self.reasons.late_damage or 0) + 1
      self.counters.late_damage = self.counters.late_damage + 1
      pcall(self.diag.note_latency, self.diag, t - m.t)
      self.bursts[uid] = { first = t, last = t, events = 1, damage = amount, shot = nil }
      self:_event(t, "late_damage", string.format("#%d damage %.0fms after shot, %.0fms past its window: miss re-classified",
        m.id, (t - m.t) * 1000, (t - m.deadline) * 1000))
      self.on_change()
      return "late"
    end
  end

  self.counters.unattributed_damage = self.counters.unattributed_damage + 1
  self.bursts[uid] = { first = t, last = t, events = 1, damage = amount, shot = nil }
  return "unattributed"
end

-- ---------------------------------------------------------------------------------------
-- Juju's own bullet confirmation (on_local_bullet_confirmed: player hit, part, damage text)
-- ---------------------------------------------------------------------------------------
-- info: { t?, uid, amount?, part? }
-- Order seen live: the target's health drops first, the confirmation follows ~85ms later. So the
-- usual case is "corroborate a hit already inferred"; if no hit was inferred yet, the confirmation
-- itself resolves the oldest pending shot (it is attributed to a LOCAL bullet by Juju).
function E:register_confirm(info)
  if self.dead then return "dead" end
  local cfg = self.cfg
  local uid = info.uid
  if uid == nil then
    self.counters.invalid_events = self.counters.invalid_events + 1
    return "invalid"
  end
  local t = info.t or self.now()
  self.counters.juju_confirms = self.counters.juju_confirms + 1

  -- pellets of one shot are confirmed together: count the shot once
  local cb = self.cbursts[uid]
  if cb and t >= cb.last and (t - cb.last) <= cfg.burst_gap then
    cb.last = t
    self.counters.confirm_pellets = self.counters.confirm_pellets + 1
    return "burst"
  end
  self.cbursts[uid] = { last = t }

  -- 1. corroborate a hit already inferred from the target's health
  for i = self.recent_hit:size(), 1, -1 do
    local h = self.recent_hit:get(i)
    if not h.juju_confirmed and h.victim == uid and t >= h.hit_t and (t - h.hit_t) <= cfg.confirm_match then
      h.juju_confirmed = true
      self:_apply(h, "confirmed_hits", 1)
      self.counters.corroborated = self.counters.corroborated + 1
      -- now known to be a local bullet: its latency may steer the window
      if h.latency then pcall(self.diag.note_latency, self.diag, h.latency, true) end
      self:_event(t, "juju_confirmed", string.format("#%d hit confirmed by Juju %.0fms after the damage",
        h.id, (t - h.hit_t) * 1000))
      self.on_change()
      return "corroborated"
    end
  end

  -- 2a. a hit deferred for lack of fire evidence: Juju says the bullet hit, so it did fire
  for i = 1, #self.pending do
    local s = self.pending[i]
    if s.deferred and s.victim == uid then
      s.deferred = nil
      s.juju_confirmed = true
      self:_finish(s, "hit", nil, t)
      self:_apply(s, "confirmed_hits", 1)
      return "hit"
    end
  end

  -- 2b. no inferred hit yet: the confirmation resolves the oldest pending shot that preceded it
  for i = 1, #self.pending do
    local s = self.pending[i]
    if not s.burst and t >= s.t and t <= s.deadline + cfg.late_grace * s.window + ZERO then
      local burst = { first = t, last = t, events = 1, damage = info.amount or 0, shot = s }
      self.bursts[uid] = burst
      s.burst = burst
      s.victim = uid
      s.damage_total = info.amount or 0
      s.damage_events = 1
      s.hit_t = t
      s.latency = t - s.t
      s.juju_confirmed = true
      self:_finish(s, "hit", nil, t)
      self:_apply(s, "confirmed_hits", 1)
      return "hit"
    end
  end

  self.counters.confirm_unmatched = self.counters.confirm_unmatched + 1
  return "unmatched"
end

-- ---------------------------------------------------------------------------------------
-- Fire evidence (optional ammo source)
-- ---------------------------------------------------------------------------------------
-- Another bullet of a shot already registered (shotgun pellet). Returns true if it was absorbed.
function E:add_pellet(t, weapon_key)
  local last = self.last_attempt[weapon_key]
  if last == nil or (t - last) > self.cfg.pellet_gap then return false end
  for i = #self.pending, 1, -1 do
    local s = self.pending[i]
    if s.weapon.key == weapon_key and s.t == last then
      s.pellets = s.pellets + 1
      return true
    end
  end
  -- the shot already resolved (a fast hit): still its pellet, do not open a new shot
  return true
end

-- info: { t?, weapon_key }
function E:register_fire(info)
  if self.dead then return "dead" end
  local t = info.t or self.now()
  local eps = self.cfg.same_frame_eps
  for i = 1, #self.pending do
    local s = self.pending[i]
    if not s.fire and s.weapon.key == info.weapon_key and t >= s.t - eps and t <= s.deadline + ZERO then
      s.fire = true
      self.counters.fires_matched = self.counters.fires_matched + 1
      self:_apply(s, "fired", 1)
      if s.deferred then
        s.deferred = nil
        self:_finish(s, "hit", nil, t)
      end
      return "matched"
    end
  end
  self.pre_fire[info.weapon_key] = t
  self.counters.fire_unmatched = self.counters.fire_unmatched + 1
  self:_event(t, "fire_unmatched", tostring(info.weapon_key) .. " ammo decrement without a pending attempt")
  return "unmatched"
end

-- ---------------------------------------------------------------------------------------
-- Context
-- ---------------------------------------------------------------------------------------
-- Respawn / weapon switch / weapon removal while shots are in flight. Damage that still arrives
-- is a hit as usual; silence becomes `unconfirmed(reason)` instead of `miss`.
-- A weapon change while shots are in flight.
--
-- LIVE FINDING: this used to call note_context("weapon_changed"), which made every affected shot
-- "unconfirmed". In the real game that discarded 100% of Double Barrel shots (the gun re-parents or
-- is swapped within the confirmation window) while costing only ~12% of knife shots, so the weapon
-- the user most cared about produced no usable statistics at all.
--
-- It was also wrong: once a bullet has left, the weapon you are holding no longer decides whether
-- it hit. Juju's on_local_bullet_confirmed attributes the hit to the local player's bullet, and
-- health-based attribution uses the shot's own time window and candidate set. So a switch is
-- recorded for diagnostics, and only disables the not_fired rule (the original weapon's ammo can no
-- longer be observed). Genuine context changes - respawn, death - still invalidate via note_context.
function E:note_weapon_switch()
  if self.dead then return end
  self.counters.weapon_switches = self.counters.weapon_switches + 1
  for i = 1, #self.pending do
    local s = self.pending[i]
    if not s.weapon_switched then
      s.weapon_switched = true
      self.counters.shots_spanning_switch = self.counters.shots_spanning_switch + 1
    end
  end
end

function E:note_context(reason)
  if self.dead then return end
  for i = 1, #self.pending do
    local s = self.pending[i]
    if not s.ctx then s.ctx = reason end
  end
end

function E:target_lost(uid)
  if self.dead then return end
  for i = 1, #self.pending do
    local s = self.pending[i]
    if is_cand(s, uid) then
      s.lost = s.lost or {}
      s.lost[uid] = true
      s.nlive = s.nlive - 1
    end
  end
  self.bursts[uid] = nil
  self.cbursts[uid] = nil
end

-- ---------------------------------------------------------------------------------------
-- Queries / lifecycle
-- ---------------------------------------------------------------------------------------
function E:stats(name)
  local b = self.buckets[name or "all"] or new_bucket()
  local out = U.shallow_copy(b)
  out.pending = b.attempted - b.hits - b.misses - b.unconfirmed - b.not_fired
  local resolved = b.hits + b.misses
  out.hit_pct = resolved > 0 and (b.hits / resolved * 100) or nil
  out.reg_pct = b.attempted > 0 and (b.hits / b.attempted * 100) or nil
  out.lat_avg = b.lat_n > 0 and (b.lat_sum / b.lat_n) or nil
  out.ratio_avg = b.ratio_n > 0 and (b.ratio_sum / b.ratio_n) or nil
  out.conf_pct = b.hits > 0 and (b.confirmed_hits / b.hits * 100) or nil
  return out
end

function E:bucket_names()
  local names = {}
  for k in pairs(self.buckets) do names[#names + 1] = k end
  table.sort(names)
  return names
end

function E:pending_count() return #self.pending end

-- Independent consistency check (bucket arithmetic vs the real pending list). Returns ok, message.
function E:check_invariant()
  for name, b in pairs(self.buckets) do
    local resolved = b.hits + b.misses + b.unconfirmed + b.not_fired
    if resolved > b.attempted or b.hits < 0 or b.misses < 0 or b.unconfirmed < 0 or b.not_fired < 0 then
      return false, "bucket " .. name .. " resolved more shots than were attempted"
    end
  end
  local all = self.buckets.all
  local derived = all.attempted - all.hits - all.misses - all.unconfirmed - all.not_fired
  if derived ~= #self.pending then
    return false, string.format("pending list has %d shots but counters imply %d", #self.pending, derived)
  end
  local n = 0
  for _ in pairs(self.by_id) do n = n + 1 end
  if n ~= #self.pending then
    return false, string.format("by_id has %d entries for %d pending shots", n, #self.pending)
  end
  return true, "ok"
end

function E:interval_stats(key)
  local ring = self.intervals[key]
  if not ring or ring:size() == 0 then return nil end
  local arr = ring:to_array()
  return { n = #arr, min = math.min(U.unpack(arr)), median = U.median(arr), last = arr[#arr] }
end

function E:recent_events(n)
  local out = {}
  local size = self.events:size()
  local from = size - (n or 10) + 1
  if from < 1 then from = 1 end
  for i = from, size do out[#out + 1] = self.events:get(i) end
  return out
end

function E:_cancel_all()
  for i = 1, #self.pending do
    local s = self.pending[i]
    if s.timer ~= nil then
      pcall(self.timers.cancel, s.timer)
      s.timer = nil
    end
  end
end

function E:reset()
  self:_cancel_all()
  self:_init_state()
  self.on_change()
end

function E:shutdown()
  self:_cancel_all()
  self.dead = true
  self.pending = {}
  self.by_id = {}
end

return E
