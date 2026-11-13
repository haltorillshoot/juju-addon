# Live findings (one real session)

Observed through a Potassium client connected to a running Hood Customs server (two clients of the same
server were attached; one was used). **The addon was started by running the bundle from the executor,
not through Juju's addon loader** (`__IDENTIFIER` was `nil`), so everything about the menu is
unverified. The addon only observed: no weapon was fired, aimed or switched by the test.

## 1. The running Juju differs from the docs

* `get_ping`, `get_flag(s)`, `set_flag`, `get_signal(s)`, `get_ragebot_target`, `get_server_cframe`,
  `get_client_cframe`, `create_tab/section/element`, `create_connection`, `on_unload`, `set_tab_text`,
  `find_element` all exist.
* Documented but **absent**: `get_ragebot_targets`, `add_ragebot_target`, `remove_ragebot_target`
  (the addon does not use them).
* **Present but undocumented** (41 functions in total), among them: `is_player_dead`,
  `is_player_knocked`, `is_player_invulnerable`, `is_in_vehicle`, `is_defensive_active`, `reload_gun`,
  `get_legitbot_target`, `set_legitbot_target`, `get_active_keybinds`, `create_notification`,
  `get/set_*_aim_position`. Not used.
* `get_flags()` returned 758 flags, including `auto_mode` (found by the addon's name heuristic) and
  `ragebot`.
* `get_signals()` returned **31 signals**, the docs list 4:
  `on_local_bullet_fired, on_local_bullet_confirmed, on_local_bullet_failed, on_player_bullet_fired,
  on_shot_at, on_local_ammo_changed, on_local_reload, on_local_reloading, on_local_tool_equipped,
  on_player_tool_equipped, on_local_health_changed, on_player_health_changed, on_local_knocked,
  on_player_knocked, on_player_died, on_stomp, on_local_character_added, ...`

## 2. Behaviour outside an addon context (the way this test ran)

* `juju.create_connection(signal, cb)` returned **nil and connected nothing** (callback fired 0 times);
  `signal:Connect` worked. -> the addon now falls back to a direct connection when it does not get a
  real connection object back, and reports `create_connection behaviour=` in its report.
* `juju.create_section(...)` returned **nil** -> menu cannot be built; reported once, tracking/HUD/console
  report still work. Whether the menu works when loaded as a real addon is **untested**.

## 3. Signal payloads actually observed (40 s of a live duel)

| Signal | Payload seen | Count in 40 s |
|---|---|---|
| `on_local_bullet_confirmed` | `(Player hit, Part e.g. HumanoidRootPart, "-15")` damage as text | 27 |
| `on_player_health_changed` | `(player-data table, newHealth, delta)` | 99 |
| `on_local_health_changed` | `(health)` | 64 |
| `on_player_bullet_fired` | `(Part BULLET_RAYS, Beam GunBeam, CFrame, boolean)`, one per pellet | 10 |
| `on_local_tool_equipped` | `(Tool)` or `nil` | 123 |
| `on_local_knocked`, `on_local_reloading` | `(boolean)` | 3, 1 |
| `on_local_bullet_fired`, `on_local_bullet_failed`, `on_local_ammo_changed`, `on_shot_at`, `on_stomp`, `on_player_died`, `on_player_knocked`, `on_local_reload` | never fired in this window | 0 |

Timing: the target's health dropped first, `on_local_bullet_confirmed` followed about **85 ms** later.
The Double Barrel's real tool name is **`[DoubleBarrel]`** (matches the default alias `doublebarrel`).
Other tool names seen: `[Knife]`, `[Pizza]`, `[Chicken]`.

## 4. Consequences implemented

* `on_local_bullet_confirmed` is used as the **strongest hit evidence** (Juju attributes it to a local
  bullet): it corroborates a health-inferred hit, or resolves the pending shot if no health event was
  seen. Hits are reported as `Hit N` and `Juju-conf M/N`. Pellet confirmations count once.
  Switch off with `use_juju_signals = false`.
* `gap_max` in the report reached ~3e9 studs: at some moment the server-side position was extremely far
  from the client (consistent with a desync/void state). The gap metric is therefore meaningful.

## 5. Still unverified

* Semantics of `on_local_bullet_fired` (never fired), whether `on_player_bullet_fired` includes your own
  shots, melee hits (a Knife produced `Tool.Activated` but no confirmations), ammo signals.
* The menu under the real addon loader; the HUD (created without error, not seen on screen).
* Whether `on_local_bullet_confirmed` fires once per shot or once per pellet in all cases (the engine
  de-duplicates pellets arriving within `burst_gap`).
