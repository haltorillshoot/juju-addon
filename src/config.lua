-- config.lua
-- Defaults, schema validation and runtime updates.
-- Precedence (lowest -> highest): defaults < USER_CONFIG table in the bundle header
--                                  < flags named jhc_cfg_<key> < menu elements.
-- Invalid values never throw: they are replaced by the default (or clamped) and reported in
-- `problems`.

local U = require("util")

local C = {}
C.VERSION = "1.0.0"

C.defaults = {
  -- feature switches
  enabled = true,            -- master switch for shot/hit tracking
  hud = true,                -- on-screen overlay (needs Drawing)
  debug = false,             -- echo log lines to the console
  tab_summary = false,       -- show a 12-char live summary on the Juju tab
  auto_mode = false,         -- Auto Mode tracking profile
  follow_host_auto = false,  -- treat Juju's own auto flag as Auto Mode ON
  host_auto_flag = "",       -- exact name of Juju's auto flag, "" = discover by name

  -- LIVE FINDING: the running Juju exposes signals the docs do not list (discovered through the
  -- documented juju.get_signals()/get_signal()). on_local_bullet_confirmed(player, part, "-15") is
  -- Juju's own confirmation that a LOCAL bullet hit someone. When present it is used as the strongest
  -- hit evidence (it removes the "somebody else's damage" ambiguity).
  use_juju_signals = true,
  confirm_match = 0.5,       -- a Juju confirmation corroborates a health-inferred hit up to this long after it (s)

  -- which players' damage can confirm a hit: "auto" (ragebot target if set, else all),
  -- "target" (ragebot target only), "all" (every other player)
  scope = "auto",

  -- hit attribution
  causal_check = true,       -- ignore damage that arrives sooner than physically possible
  causal_ratio = 0.5,        -- ... i.e. earlier than causal_ratio * ping at shot time
  burst_gap = 0.03,          -- damage events closer than this (s) are one shot's pellets
  dedupe_eps = 0.02,         -- attempts closer than this (s) on one weapon = duplicate event
  same_frame_eps = 0.004,    -- tolerance for event-order differences inside one frame (s)
  late_grace = 0.5,          -- damage up to late_grace * window AFTER a declared miss re-classifies it
  timer_late_tol = 0.1,      -- expiry timer firing this late (s) means the client stalled

  -- adaptive confirmation window (seconds)
  window_min = 0.20,
  window_max = 1.5,
  window_default = 0.5,      -- used until ping samples exist
  window_rtt_mult = 1.5,     -- window = mult * RTT + jitter_mult * jitter + floor
  window_jitter_mult = 2.0,
  window_floor = 0.05,       -- server processing allowance
  -- OFF by default. The simulation (docs/SIM_RESULTS.md) showed a feedback loop: damage dealt by
  -- OTHER players gets counted as "hit latency", which lengthens the window, which admits more
  -- unrelated damage... until the window sits at window_max. Enable only if the game's damage
  -- replication is known to be slower than ping suggests.
  learn_window = false,
  window_emp_mult = 1.25,    -- (learn_window) multiplier on p95 of observed hit latency
  window_emp_min = 6,        -- (learn_window) observations needed before it is used

  -- connection diagnostics
  diag_interval = 1.0,       -- background ping sample period (s)
  diag_samples = 64,
  ewma_alpha = 0.2,
  spike_ratio = 2.5,
  spike_min_ms = 80,
  disconnect_ping_ms = 2000,
  stall_factor = 3.0,
  gap_warn = 8,              -- studs of server/client position gap worth flagging

  -- ui
  ui_refresh = 0.25,         -- minimum seconds between UI/flag refreshes
  log_size = 200,
  hud_x = 20,
  hud_y = 200,
  hud_size = 14,

  -- weapon identification (letters only, lower case; matched as substrings)
  weapon_aliases = { "doublebarrel", "dbarrel", "dbsg" },
  ammo_patterns = { "ammo", "clip", "magazine", "shell", "bullet" },   -- word start/end match
}

-- schema: { kind, min/max or enum list }
local SCHEMA = {
  enabled = { "boolean" }, hud = { "boolean" }, debug = { "boolean" },
  tab_summary = { "boolean" }, auto_mode = { "boolean" },
  follow_host_auto = { "boolean" }, host_auto_flag = { "string" },
  use_juju_signals = { "boolean" }, confirm_match = { "number", 0.05, 2 },
  scope = { "enum", { "auto", "target", "all" } },
  causal_check = { "boolean" }, causal_ratio = { "number", 0, 1 },
  burst_gap = { "number", 0, 0.1 }, dedupe_eps = { "number", 0, 0.1 },
  same_frame_eps = { "number", 0, 0.05 }, late_grace = { "number", 0, 2 },
  timer_late_tol = { "number", 0.02, 2 },
  window_min = { "number", 0.05, 5 }, window_max = { "number", 0.1, 10 },
  window_default = { "number", 0.05, 10 },
  window_rtt_mult = { "number", 0.5, 10 }, window_jitter_mult = { "number", 0, 10 },
  window_floor = { "number", 0, 1 }, learn_window = { "boolean" }, window_emp_mult = { "number", 1, 5 },
  window_emp_min = { "number", 1, 32 },
  diag_interval = { "number", 0.25, 30 }, diag_samples = { "number", 8, 512 },
  ewma_alpha = { "number", 0.01, 1 }, spike_ratio = { "number", 1.1, 20 },
  spike_min_ms = { "number", 0, 5000 }, disconnect_ping_ms = { "number", 100, 60000 },
  stall_factor = { "number", 1.5, 50 }, gap_warn = { "number", 0, 1000 },
  ui_refresh = { "number", 0.05, 5 }, log_size = { "number", 10, 2000 },
  hud_x = { "number", 0, 8000 }, hud_y = { "number", 0, 8000 }, hud_size = { "number", 8, 48 },
  weapon_aliases = { "strlist" }, ammo_patterns = { "strlist" },
}
C.schema = SCHEMA

local function copy_default(v)
  if type(v) == "table" then
    local r = {}
    for i = 1, #v do r[i] = v[i] end
    return r
  end
  return v
end

-- Returns (value, note) on success, (nil, reason) when the input is unusable.
local function coerce(spec, v)
  local kind = spec[1]
  if kind == "boolean" then
    if type(v) == "boolean" then return v end
    if v == 1 or v == "1" or v == "true" then return true end
    if v == 0 or v == "0" or v == "false" then return false end
    return nil, "expected boolean"
  elseif kind == "number" then
    if type(v) == "string" then v = tonumber(v) end
    if not U.is_finite(v) then return nil, "expected a finite number" end
    local lo, hi = spec[2], spec[3]
    if v < lo then return lo, "clamped up to " .. tostring(lo) end
    if v > hi then return hi, "clamped down to " .. tostring(hi) end
    return v
  elseif kind == "enum" then
    if type(v) == "string" then
      local s = string.lower(v)
      for i = 1, #spec[2] do
        if spec[2][i] == s then return s end
      end
    end
    return nil, "expected one of " .. table.concat(spec[2], "/")
  elseif kind == "string" then
    if type(v) == "string" then return v end
    return nil, "expected string"
  elseif kind == "strlist" then
    local items = {}
    if type(v) == "string" then
      for piece in string.gmatch(v, "[^,;]+") do items[#items + 1] = piece end
    elseif type(v) == "table" then
      for i = 1, #v do items[#items + 1] = v[i] end
    else
      return nil, "expected list of strings"
    end
    local out = {}
    for i = 1, #items do
      local n = U.normalize_name(items[i])
      if n ~= "" then out[#out + 1] = n end
    end
    if #out == 0 then return nil, "list is empty after normalisation" end
    return out
  end
  return nil, "unknown schema kind"
end

-- Cross-field rules. Mutates `values`, appends to `problems`.
local function fix_cross(values, problems)
  if values.window_min > values.window_max then
    problems[#problems + 1] = "window_min > window_max: both reset to defaults"
    values.window_min = C.defaults.window_min
    values.window_max = C.defaults.window_max
  end
  local d = U.clamp(values.window_default, values.window_min, values.window_max)
  if d ~= values.window_default then
    problems[#problems + 1] = "window_default outside [window_min, window_max]: clamped"
    values.window_default = d
  end
end

function C.sanitize(raw)
  local values, problems = {}, {}
  for k, v in pairs(C.defaults) do values[k] = copy_default(v) end
  if raw ~= nil and type(raw) ~= "table" then
    problems[#problems + 1] = "config is not a table: ignored"
    raw = nil
  end
  if raw then
    for k, v in pairs(raw) do
      local spec = SCHEMA[k]
      if not spec then
        problems[#problems + 1] = tostring(k) .. ": unknown key ignored"
      else
        local nv, note = coerce(spec, v)
        if nv == nil then
          problems[#problems + 1] = k .. ": " .. tostring(note) .. " (default kept)"
        else
          values[k] = nv
          if note then problems[#problems + 1] = k .. ": " .. note end
        end
      end
    end
  end
  fix_cross(values, problems)
  return values, problems
end

-- ---------------------------------------------------------------------------------------
-- Config object: `values` is a plain table other modules read directly.
-- ---------------------------------------------------------------------------------------
local Obj = {}
Obj.__index = Obj

function C.new(raw)
  local values, problems = C.sanitize(raw)
  return setmetatable({ values = values, problems = problems, listeners = {} }, Obj)
end

function Obj:set(key, value)
  local spec = SCHEMA[key]
  if not spec then return false, "unknown key" end
  local nv, note = coerce(spec, value)
  if nv == nil then
    self.problems[#self.problems + 1] = key .. ": " .. tostring(note)
    return false, note
  end
  if note then self.problems[#self.problems + 1] = key .. ": " .. note end
  self.values[key] = nv
  -- a user moving one window bound past the other drags the other bound along (instead of
  -- the config-file rule of resetting both to defaults)
  local v = self.values
  if key == "window_min" and v.window_min > v.window_max then
    v.window_max = U.clamp(v.window_min, 0.1, 10)
  elseif key == "window_max" and v.window_max < v.window_min then
    v.window_min = U.clamp(v.window_max, 0.05, 5)
  end
  fix_cross(self.values, self.problems)
  for i = 1, #self.listeners do
    pcall(self.listeners[i], key, self.values[key])
  end
  return true
end

function Obj:on_change(fn)
  self.listeners[#self.listeners + 1] = fn
end

-- Reads jhc_cfg_<key> flags through `get_flag(name)`; invalid entries are reported, not applied.
function Obj:load_flags(get_flag)
  local applied = 0
  for key in pairs(SCHEMA) do
    local raw = get_flag("jhc_cfg_" .. key)
    if raw ~= nil then
      if self:set(key, raw) then applied = applied + 1 end
    end
  end
  return applied
end

return C
