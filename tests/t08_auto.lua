local T = require("tf")
local H = require("harness")
local Auto = require("automode")
local Config = require("config")

T.suite("08 Auto Mode state handling")

local function unit(cfg_over)
  local cfg = Config.new(cfg_over).values
  local log = {}
  local a = Auto.new({ cfg = cfg, log = function(l, m) log[#log + 1] = m end,
    on_change = function(o, n, r) log[#log + 1] = o .. ">" .. n .. ":" .. r end })
  return a, log, cfg
end

T.test("unit: state table OFF / ARMED / ACTIVE / SUSPENDED", function()
  local a = unit()
  T.eq(a.state, "OFF")
  a:set_enabled(true)
  T.eq(a.state, "ARMED"); T.eq(a.reason, "no_character")
  a:update({ char_alive = true })
  T.eq(a.reason, "weapon_not_dbs")
  a:update({ weapon_is_dbs = true })
  T.eq(a.state, "ACTIVE")
  a:update({ degraded = true })
  T.eq(a.state, "SUSPENDED")
  a:update({ degraded = false })
  T.eq(a.state, "ACTIVE")
  a:update({ char_alive = false })
  T.eq(a.state, "ARMED")
  a:set_enabled(false)
  T.eq(a.state, "OFF")
end)

T.test("unit: transitions are reported once, idempotent updates are silent", function()
  local a, log = unit({ auto_mode = true })
  local n = a.transitions
  a:update({ char_alive = true }); a:update({ char_alive = true }); a:update({ char_alive = true })
  T.eq(a.transitions, n + 1)
  a:set_enabled(true); a:set_enabled(true)
  T.eq(a.transitions, n + 1)
end)

T.test("unit: shots in ACTIVE and SUSPENDED are tagged auto; ARMED/OFF manual", function()
  local a = unit()
  T.eq(a:mode_tag(), "manual")
  a:set_enabled(true); a:update({ char_alive = true, weapon_is_dbs = true })
  T.eq(a:mode_tag(), "auto")
  a:update({ degraded = true })
  T.eq(a:mode_tag(), "auto")
  a:update({ weapon_is_dbs = false })
  T.eq(a:mode_tag(), "manual")
end)

T.test("unit: follow_host_auto only matters when enabled in config", function()
  local a = unit()
  a:update({ char_alive = true, weapon_is_dbs = true, host_auto = true })
  T.eq(a.state, "OFF")
  local b = unit({ follow_host_auto = true })
  b:update({ char_alive = true, weapon_is_dbs = true, host_auto = true })
  T.eq(b.state, "ACTIVE")
  b:update({ host_auto = false })
  T.eq(b.state, "OFF")
  b:update({ host_auto = nil })
  T.eq(b.state, "OFF")
end)

T.test("integration: toggling Auto Mode with the DBS equipped -> ACTIVE", function()
  local c = H.standard()
  T.eq(c.inst.auto.state, "OFF")
  c.J.user_set("Auto Mode", "Auto Mode DBS", true)
  T.eq(c.inst.auto.state, "ACTIVE")
  H.run(c, 0.6)
  T.eq(c.J.flags.jhc_auto_state, "ACTIVE")
  c.J.user_set("Auto Mode", "Auto Mode DBS", false)
  T.eq(c.inst.auto.state, "OFF")
end)

T.test("integration: other weapon -> ARMED(weapon_not_dbs); switching to DBS activates", function()
  local c = H.standard({ tool_name = "[Revolver]" })
  c.J.user_set("Auto Mode", "Auto Mode DBS", true)
  T.eq(c.inst.auto.state, "ARMED"); T.eq(c.inst.auto.reason, "weapon_not_dbs")
  local dbs = c.g:give_tool(c.me, "[Double-Barrel SG]")
  c.g:unequip(c.me, c.tool); c.g:equip(c.me, dbs)
  T.eq(c.inst.auto.state, "ACTIVE")
  c.g:unequip(c.me, dbs)
  T.eq(c.inst.auto.state, "ARMED")
end)

T.test("integration: death/respawn -> ARMED(no_character) -> ACTIVE after re-equip", function()
  local c = H.standard()
  c.J.user_set("Auto Mode", "Auto Mode DBS", true)
  c.g:despawn(c.me)
  T.eq(c.inst.auto.state, "ARMED"); T.eq(c.inst.auto.reason, "no_character")
  c.g:spawn(c.me)
  T.eq(c.inst.auto.reason, "weapon_not_dbs")
  local t2 = c.g:give_tool(c.me, "[Double-Barrel SG]")
  c.g:equip(c.me, t2)
  T.eq(c.inst.auto.state, "ACTIVE")
end)

T.test("integration: ping spike suspends, recovery re-activates", function()
  local c = H.standard()
  c.J.user_set("Auto Mode", "Auto Mode DBS", true)
  H.run(c, 8)
  T.eq(c.inst.auto.state, "ACTIVE")
  c.J.ping = 1500
  H.run(c, 1.2)
  T.eq(c.inst.auto.state, "SUSPENDED"); T.eq(c.inst.auto.reason, "connection_degraded")
  c.J.ping = 60
  H.run(c, 4)
  T.eq(c.inst.auto.state, "ACTIVE")
end)

T.test("integration: shots are bucketed auto vs manual by the state at shot time", function()
  local c = H.standard()
  H.shoot_hit(c, c.enemies[1], 0.07, 10); H.run(c, 1)                 -- manual
  c.J.user_set("Auto Mode", "Auto Mode DBS", true)
  H.shoot_hit(c, c.enemies[1], 0.07, 10); H.run(c, 1)                 -- auto
  H.shoot(c); H.run(c, 1)                                              -- auto miss
  c.J.user_set("Auto Mode", "Auto Mode DBS", false)
  H.shoot(c); H.run(c, 1)                                              -- manual miss
  local a, m = H.stats(c, "mode:auto"), H.stats(c, "mode:manual")
  T.eq(a.attempted, 2); T.eq(a.hits, 1); T.eq(a.misses, 1)
  T.eq(m.attempted, 2); T.eq(m.hits, 1); T.eq(m.misses, 1)
  T.eq(H.stats(c).attempted, 4)
  H.check_invariant(c, T)
end)

T.test("Auto Mode does NOT change classification: identical session, identical outcomes", function()
  local function session(auto_on)
    local c = H.standard({ enemies = 2, ammo = 2 })
    if auto_on then c.J.user_set("Auto Mode", "Auto Mode DBS", true) end
    local outcomes = {}
    local plan = { "hit", "miss", "hit", "nofire", "miss", "hit" }
    for _, p in ipairs(plan) do
      H.shoot(c)
      if p ~= "nofire" then c.tool.ammo:SetValue(c.tool.ammo.Value - 1) end
      if p == "hit" then H.damage_after(c, c.enemies[1], 0.08, 10) end
      H.run(c, 1)
      c.tool.ammo:SetValue(2)
      outcomes[#outcomes + 1] = c.inst.engine.last_shot.outcome
    end
    return table.concat(outcomes, ","), c
  end
  local off, c1 = session(false)
  local on, c2 = session(true)
  T.eq(on, off)
  T.eq(off, "hit,miss,hit,not_fired,miss,hit")
  T.eq(H.stats(c2, "mode:auto").attempted, 6)
  T.eq(H.stats(c1, "mode:manual").attempted, 6)
end)

T.test("Auto Mode never fires or aims: weapon activations equal what the test did", function()
  local c = H.standard()
  local activations = 0
  c.tool.Activated:Connect(function() activations = activations + 1 end)
  c.J.user_set("Auto Mode", "Auto Mode DBS", true)
  c.J.ragebot_target = c.enemies[1]
  c.J.flags.ragebot = true
  H.run(c, 30)
  T.eq(activations, 0, "addon must never activate the tool")
  H.shoot(c); H.run(c, 1)
  T.eq(activations, 1)
  T.eq(#c.J.violations, 0, "no ragebot/teleport/purchase calls")
end)

T.test("host auto flag: discovered by name via get_flags, followed only when asked", function()
  local c = H.standard({ pre = function(x) x.J.flags.auto_mode = true; x.J.flags.other = 1 end })
  H.run(c, 1.5)
  T.eq(c.inst.world.host_flag_name, "auto_mode")
  T.eq(c.inst.auto.ctx.host_auto, true)
  T.eq(c.inst.auto.state, "OFF", "not followed by default")
  c.J.user_set("Auto Mode", "Follow Juju auto", true)
  T.eq(c.inst.auto.state, "ACTIVE")
  c.J.flags.auto_mode = false
  H.run(c, 1.5)
  T.eq(c.inst.auto.state, "OFF")
end)

T.test("host auto flag: explicit name via config; unknown flag -> host_auto stays nil", function()
  local c = H.standard({ config = { host_auto_flag = "my_auto", follow_host_auto = true },
    pre = function(x) x.J.flags.my_auto = true end })
  H.run(c, 1.5)
  T.eq(c.inst.auto.ctx.host_auto, true)
  T.eq(c.inst.auto.state, "ACTIVE")
  local d = H.standard()
  H.run(d, 1.5)
  T.is_nil(d.inst.auto.ctx.host_auto)
  T.contains(d.inst.report(), "host_auto=nil")
end)

T.test("host flag rescans are rate limited (get_flags is a host call)", function()
  local c = H.standard()
  H.run(c, 61)
  T.ok(c.J.count_calls("get_flags") <= 3, "get_flags called " .. c.J.count_calls("get_flags") .. " times")
end)

return true
