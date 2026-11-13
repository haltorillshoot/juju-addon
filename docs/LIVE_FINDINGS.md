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

## 4b. Second run (107 attempts, after the fixes) - the numbers that changed the window

```
[all] att=107 hit=14 miss=68 unconf=25 pend=0  hit%=17.1%  lat(avg/min/max)=156ms/112ms/226ms
      hits also confirmed by Juju's own bullet signal: 14 of 14
      hit latency / ping at shot = 2.90
ping=52ms p95=53ms jitter=0ms samples=195 spikes=0 stalls=0 window=200ms
juju native hit signal: hooked  confirms=14 corroborated=0 pellets=0 unmatched=0
connections: create_connection behaviour=noop_returns_nil direct-connect fallbacks=56
unconfirmed reasons: weapon_changed=25
```

Two things stand out:

1. **`corroborated=0`** - every hit was resolved by the Juju signal; `Humanoid.HealthChanged` on the
   victim never produced one. The health-based detection this addon was originally built on appears
   not to work for other players in this game, at least for a knife. **The native signal is essential,
   not a bonus.**
2. **Hit latency ~2.9 x ping**, up to 226 ms against a 200 ms window: the slowest hits only counted
   because of the late-damage grace. The window now learns from Juju-confirmed latencies (see
   `docs/TEST_REPORT.md`), which is safe precisely because Juju attributes them to the local bullet.

Unloading was also verified live: 9 HUD objects removed, registry entry cleared, `jhc_loaded` set back
to `false`, and reloading the bundle shut the previous instance down first.

## 4c. Third run - guns do not fire Tool.Activated

With a gun equipped the addon recorded **0 shot attempts while Juju confirmed 9 hits**
(`unmatched=9`: it refused to invent shots). Probing showed why:

* `Tool.Activated` fires for **melee** (the knife run counted 107 attempts) but **not for guns**.
* `on_local_bullet_fired` never fires in this build (0 events while bullets were clearly being fired).
* `on_player_bullet_fired` fires **once per bullet/pellet**, payload
  `(Part BULLET_RAYS, Beam GunBeam, CFrame, boolean)`.

Is that signal global or local? Listening on **both clients at once for the same 25 s** gave
`dECqyVEu: 20` and `TvjsKLvR: 40`. A server-wide signal would give both clients the same count, so
**each client receives only its own bullets**. It is therefore used as the shot-attempt source for
guns, with pellets inside `pellet_gap` (50 ms, measured from the start of the pull) counted as one
shot. `use_bullet_signal = false` disables it.

The weapon is a normal Tool on the character after all: `Tool:[DoubleBarrel]` (the earlier
"no tool equipped" was a respawn moment). Backpack seen: `[Revolver]`, `[TacticalShotgun]`,
`[Knife]`, `[Pizza]`, `[Burger]`, `[Taco]`, `[Chicken]`, `[Tip Jar]`. The real Double Barrel name
`[DoubleBarrel]` matches the shipped alias `doublebarrel`.

## 4d. Final run - both shot sources working end to end

After the gun fix, with the counters reset and ~30 s of play:

```
shots=114 hits=15 miss=76 unconf=23 nofire=0 pend=0 hit%=16.5%  jujuConf=15/15
window=497ms trusted=15 trustedP95=397ms  lat(avg/min/max)=219ms/65ms/397ms
bullets=15  invariant=true
events: #115 knife via=activated ... | gun shots via=bullet
```

* Both sources ran together: melee through `Tool.Activated` (`via=activated`), gun shots through the
  bullet signal, with 15 bullets coalescing into their trigger pulls.
* A separate check isolated the coalescing: **raw signal 5 bullets -> addon 5 bullets -> 1 shot**
  (one Double Barrel pull).
* **The window grew 200 ms -> 497 ms** by itself, from 15 Juju-confirmed latencies (p95 397 ms).
  Under the previous fixed window every hit slower than 200 ms - and real hits reached 397 ms - would
  have been reported as a miss. This is the trusted-latency change paying off on real data.
* Weapon identification live: `Weapon: [DoubleBarrel] [DBS]`, `key=doublebarrel dbs=true`.
* `invariant=true` throughout; unload removed all 9 HUD objects and cleared `jhc_loaded`.

Note the ~16% hit rate is simply how the session went (long-range shooting, knife swings at air); it is
a measurement, not a target.

## 5. Still unverified

* Semantics of `on_local_bullet_fired` (never fired), whether `on_player_bullet_fired` includes your own
  shots, melee hits (a Knife produced `Tool.Activated` but no confirmations), ammo signals.
* The menu under the real addon loader; the HUD (created without error, not seen on screen).
* Whether `on_local_bullet_confirmed` fires once per shot or once per pellet in all cases (the engine
  de-duplicates pellets arriving within `burst_gap`).
