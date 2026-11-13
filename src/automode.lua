-- automode.lua
-- Auto Mode state machine. Pure logic.
--
-- IMPORTANT: this does not fire weapons. The Juju docs expose no firing API, so Auto Mode here is
-- a tracking/gating mode: it knows whether the Double Barrel Shotgun is equipped and the
-- connection is healthy, and tags each shot "auto" or "manual" so the two can be compared.
--
--   OFF        mode disabled (and Juju's own auto flag not followed / not set)
--   ARMED      enabled, waiting: no character, or the equipped weapon is not the DBS
--   ACTIVE     enabled, character alive, DBS equipped, connection healthy
--   SUSPENDED  enabled, DBS equipped, but the connection is degraded (spike / stall)

local A = {}
A.__index = A

function A.new(deps)
  local self = setmetatable({}, A)
  self.cfg = deps.cfg
  self.log = deps.log or function() end
  self.on_change = deps.on_change or function() end
  self.enabled = deps.cfg.auto_mode and true or false
  self.ctx = { char_alive = false, weapon_is_dbs = false, degraded = false, host_auto = nil }
  self.state = "OFF"
  self.reason = "disabled"
  self.transitions = 0
  self:_recompute()
  return self
end

function A:effective_enabled()
  if self.enabled then return true end
  return (self.cfg.follow_host_auto and self.ctx.host_auto == true) and true or false
end

function A:_recompute()
  local state, reason
  if not self:effective_enabled() then
    state, reason = "OFF", "disabled"
  elseif not self.ctx.char_alive then
    state, reason = "ARMED", "no_character"
  elseif not self.ctx.weapon_is_dbs then
    state, reason = "ARMED", "weapon_not_dbs"
  elseif self.ctx.degraded then
    state, reason = "SUSPENDED", "connection_degraded"
  else
    state, reason = "ACTIVE", "ready"
  end
  if state ~= self.state or reason ~= self.reason then
    local old = self.state
    self.state, self.reason = state, reason
    self.transitions = self.transitions + 1
    self.log("info", string.format("auto mode %s -> %s (%s)", old, state, reason))
    self.on_change(old, state, reason)
  end
end

function A:set_enabled(on)
  self.enabled = on and true or false
  self:_recompute()
end

-- patch: any of char_alive, weapon_is_dbs, degraded, host_auto
function A:update(patch)
  for k, v in pairs(patch) do self.ctx[k] = v end
  self:_recompute()
end

-- Shots taken while Auto Mode is ACTIVE or SUSPENDED count as "auto" (SUSPENDED shots are exactly
-- the interesting unreliable ones, so they must not be hidden from the auto statistics).
function A:mode_tag()
  if self.state == "ACTIVE" or self.state == "SUSPENDED" then return "auto" end
  return "manual"
end

function A:is_active() return self.state == "ACTIVE" end

return A
