# Juju API reference summary (audit result)

Source: https://juju-6.gitbook.io/juju-docs, every page listed in its `llms.txt` index
(51 pages) was downloaded as raw Markdown and read on 2026-11-13 (append `.md` to any docs URL to get
the raw page). The copies are not redistributed here.

## 0. Headline findings

1. The docs contain **two separate addon APIs**:
   * the generic **`juju.*`** API (pages `ui`, `connections`, `signals`, `flags`, `ragebot`,
     `player`, `game`, `misc`, `examples`) - this has Hood-style features (`is_auto_stomping`,
     `purchase_item("shotgun")`, `set_server_cframe`), so this addon targets it. **The docs never
     say which game this API is for. "It is the Hood Customs API" is an inference, not a fact.**
   * the **`rivals.*`** API (section "Rivals") - Linoria UI, `getgenv()["rivals"]`. Different game,
     different API. **Not used.**
2. A text search of all pages for `exploit, lag, desync, hood, barrel, shotgun, auto mode, hit,
   shot, damage, weapon, tool, ammo, fire, equip` finds **nothing relevant**. In particular the
   docs do **not** contain:
   * any description of a "connection exploit" (the only hit is the word "desync" inside the
     `get_client_cframe` example, which prints the server/client position gap),
   * any page on Hood Customs, Double Barrel Shotgun, or an "Auto Mode",
   * any shot-fired, hit, damage, weapon, tool, ammo or firing API/event.
3. The only documented network/timing observables are `juju.get_ping()` and the pair
   `juju.get_server_cframe()` / `juju.get_client_cframe()`.

Consequence: everything the request calls "documented" beyond that list cannot be taken from the
Juju docs. The addon therefore (a) uses the documented Juju API for everything it covers, (b) uses
**standard Roblox engine instances/signals** (Tool, Humanoid, Players...) for shot/hit/weapon
observation, which `juju.create_connection` explicitly accepts (it takes any `RBXScriptSignal`),
and (c) labels every observation source with its provenance and confidence. See section 4.

## 1. Documented `juju.*` functions

| Function | Signature (as documented) | Notes / caveats |
|---|---|---|
| `juju.create_tab` | `(func?: () -> ()): nil` | Creates tab in "Addons" group. Must precede `create_section`. |
| `juju.create_section` | `(name, side, size, offset): section` | side 1=left 2=right; size 0-1; offset 0-0.9. Page text says both "most recently created tab" and "previously created tab". |
| `juju.create_element` / `section:create_element` | `juju.create_element(section: string, info: table, elements: table): element` | **Doc inconsistency:** the signature shows a `section: string` first parameter, every example uses method form `section:create_element(info, elements)`. We use the method form (examples). |
| element `info` | `{name=..., type="toggle"}`, `{name=..., type="slider", min=, max=}` | **Only `toggle` and `slider` are documented.** No label/button/text/dropdown. Slider step/default/rounding undocumented. |
| element `elements` | `{ callback = function(val) end }` | Only `callback` documented. |
| `juju.find_element` | `(parent: string, name: string): element` | Do not use names containing "config" or "unload". `element:set_value(v)` appears only here. |
| `juju.set_tab_text` | `(text: string): nil` | Truncated to 12 characters. |
| `juju.create_connection` | `(signal: RBXScriptSignal, callback): RBXScriptConnection` | Auto-disconnected on unload. Doc example uses `Players.PlayerAdded`, i.e. any engine signal works. |
| `juju.on_unload` | `(func): nil` | Cleanup hook. Example references `Drawing` objects (`d:Remove()`). |
| `juju.get_signal` | `(name): signal` | |
| `juju.get_signals` | `(): {string}` | "Example output": `on_ragebot_target_changed`, `on_legitbot_target_changed`, `on_target_changed`, `on_player_status_changed`. Presented as example output, so not guaranteed complete. |
| `juju.get_flag` | `(flag): any` | nil if missing or reserved. `"ragebot"` is the one documented built-in flag. |
| `juju.set_flag` | `(flag, value): nil` | Never `author`, `date`, `loaded_addons`. Documented for "custom addon state". |
| `juju.get_flags` | `(): {string}` | Excludes author/date/loaded_addons. |
| `juju.get_ragebot_target` | `(): Player?` | |
| `juju.get_ragebot_targets` | `(): {Player}` | |
| `juju.set/add/remove_ragebot_target` | various | **Mutating - never called by this addon.** |
| `juju.get_player_status` / `set_player_status` | `1` neutral, `2` friend, `3` enemy | set is **mutating - never called**. |
| `juju.is_in_void`, `juju.is_auto_stomping` | `(): boolean` | Not needed. |
| `juju.get_ping` | `(): number` | "current ping in milliseconds". Whether RTT or one-way is **not stated**. |
| `juju.get_server_cframe` / `get_client_cframe` | `(): CFrame` | HumanoidRootPart, server vs client side. Doc example computes the gap as "desync". |
| `juju.set_server_cframe` | `(cf): nil` | **Mutating (server-side teleport) - never called.** |
| `juju.purchase_item`, `is_purchasing`, `load_config` | | Not used. `load_config` loads Juju's own `.cfg`, unrelated to addon config. |

Other facts: addons get `__IDENTIFIER` injected (type unspecified). Examples use `task.spawn`,
`task.wait`, `game:GetService`, `table.clear`, generalized `for x in tbl do`. The generic API
docs do not say where addon files live (the Rivals docs say `JujuRivals/addons/`).

## 2. Things the docs do not say (and that this addon therefore does not assume)

* Error behaviour of any function (throw vs nil).
* Whether `get_ping` is RTT; its sampling rate; whether it can be 0/nil.
* Whether element objects returned by `create_element` have `set_value` (only shown on `find_element` results). Used under `pcall` only.
* Whether flags persist across sessions.
* The names of Juju's own auto/ragebot mode flags (only `"ragebot"` is documented).
* How to fire a weapon, or whether Juju exposes anything about weapons.
* How multi-file addons are loaded -> the shipped addon is **one bundled file**.

## 3. Standard Roblox APIs the addon relies on (NOT Juju-documented)

These are real, long-standing Roblox engine APIs, but they are not part of the Juju docs, and
Hood Customs may not use them the way a default Roblox game does. Each has a graceful fallback or
an explicit "unobservable" label.

| API | Used for | Risk |
|---|---|---|
| `Players.LocalPlayer`, `Player.CharacterAdded/CharacterRemoving`, `Players.PlayerAdded/PlayerRemoving`, `Players:GetPlayers()` | respawn/context tracking, target discovery | very low |
| `Character.ChildAdded/ChildRemoved`, `Instance:IsA("Tool")` | equipped weapon detection (a Tool parented to the character = equipped) | low |
| `Tool.Activated` | **shot attempt** (input-level, see below) | medium: game may fire via its own input handling instead |
| `Humanoid.HealthChanged`, `Humanoid.Died` | **server-replicated damage** on other players -> hit confirmation | medium: game may use custom health values |
| `ValueBase.Changed` / `Instance:GetAttributeChangedSignal` on a numeric ammo-like child/attribute | optional "weapon actually fired" evidence | game specific; optional |
| `task.delay/spawn/wait/cancel`, `os.clock` | timers | very low |
| `Drawing.new("Text")` | optional on-screen HUD | executor-standard; indirectly referenced by the `on_unload` doc example |

## 4. Capability matrix for the Hit Checker (what can and cannot be observed)

| Needed fact | Observable? | Source | Confidence / limitation |
|---|---|---|---|
| Shot was **attempted** | Yes | `Tool.Activated` on equipped tool | Input level. Does not prove the gun fired (cooldown, empty). |
| Shot **actually fired** | Only if game exposes numeric ammo | decrement of ammo-like value/attribute | Optional; reported as "fire-confirmed" or n/a. |
| **Hit registered** | Yes, indirectly | other player's `Humanoid.Health` decreased (server-replicated), after the shot, not earlier than the ping-derived causal floor | Strong evidence of damage to that player; **attribution to *my* shot is probabilistic** (another player may deal damage). Reported as "confirmed hit" only when no earlier-than-causality, no coalescing/overlap ambiguity. |
| **Miss** | Only by absence | no damage within an adaptive window, healthy connection, >=1 observable target | Reported as "miss" only if connection was healthy; otherwise "unconfirmed". |
| Round-trip latency | Yes | `juju.get_ping()` | Unit ms. RTT-vs-one-way not documented. |
| Client/server position gap | Yes | `abs(get_server_cframe - get_client_cframe)` | Documented example. |
| Packet loss, server tick, jitter source, lag-switch state | **No** | - | Not exposed. Jitter is *derived* from ping samples only. |
| **How the "connection exploit" works / whether it is active** | **No** | - | Not documented. The addon does not detect or implement it; it only measures ping, position gap and shot->damage latency around each shot. |
| Juju's own "Auto Mode" state | **No** (only `"ragebot"` flag documented) | `get_flags()` discovery + name heuristic, user override | Heuristic; labelled "host auto: unknown" when not found. |
| Double Barrel Shotgun identity | Yes, heuristically | normalized `Tool.Name` vs alias list | In-game tool name unverified; aliases are configurable. |

## 5. Design rules derived from the audit

1. Read-only toward Juju: the addon never calls `set_ragebot_target`, `set_player_status`,
   `set_server_cframe`, `purchase_item`, `load_config`, and only writes flags named `jhc_*`.
   Enforced in code (`host.set_flag` rejects other names) and by a test that spies on every Juju call.
2. UI uses only documented element types: `toggle`, `slider`.
3. Time-based decisions come from measured ping/latency, never from fixed sleeps. The few remaining
   numeric thresholds are explicit, validated, user-adjustable config values.
4. Hits are only reported from replicated damage; absence of damage under a degraded connection is
   "unconfirmed", never "miss".
5. **Auto Mode never fires weapons.** No documented API exists for firing, and guessing one would
   break the rule "do not invent API". In this addon Auto Mode is a tracking/gating mode (see PLAN).
