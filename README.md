# JHC Hit Checker for Juju (Hood Customs)

A Juju addon that measures how reliably your shots register: shot attempts, **confirmed** hits,
misses, unconfirmed and not-fired shots, with connection diagnostics and a Double Barrel Shotgun
profile. Single file: `dist/jhc_hood_customs.lua`.

> Read `docs/API_REFERENCE.md` first. The Juju docs contain **no** page on a connection exploit,
> Hood Customs, the Double Barrel Shotgun, an Auto Mode, or any shot/hit/weapon API. This addon
> therefore (a) uses the documented `juju.*` API for everything it covers and (b) observes
> shots/hits through standard Roblox instances (`Tool.Activated`, `Humanoid.HealthChanged`),
> labelling that clearly. **It does not detect, implement or "improve" the connection exploit, and
> its Auto Mode does not fire weapons.**

## Install / run

**As a Juju addon (this is what puts it in the menu):** copy `dist/JHC Hit Checker.luau` into
`juju recode/addons/`, then in Juju open **Addons -> refresh addon list -> pick it -> load addon**.

> **The file name matters.** Juju's loader lists the folder and takes the extension with
> `string.match(name, "%.(.*)")` - everything after the **first** dot - and only accepts exactly
> `luau`. So `MyAddon.luau` works, while `MyAddon.LUAU.txt` or `MyAddon.lua` are ignored silently
> (that is why a file saved as `.LUAU.txt` never shows up in the list).

Loading it from an executor console instead works for tracking, the HUD and the console report, but
Juju only hands the menu API to scripts its own loader runs, so no menu is built that way.

Quickest: run `loader.lua` from Juju (it downloads `dist/jhc_hood_customs.lua` from this repo and runs
it; pin `REF` to a commit SHA for safety). Or load `dist/jhc_hood_customs.lua` yourself:

Put `dist/jhc_hood_customs.lua` wherever your Juju build loads addon scripts from and load it
there. (The generic `juju.*` docs do not say where; the separate Rivals docs say
`JujuRivals/addons/` + Settings -> Addons. Use whatever your build documents.)
On load it prints `[JHC] v1.0.0 loaded ...`. A second load replaces the first instance cleanly.

## What the numbers mean

Every shot attempt ends in exactly one outcome (`attempted = hit + miss + unconfirmed + not_fired + pending`):

| Outcome | Meaning |
|---|---|
| **hit** | Another player's Humanoid health dropped after your shot, no sooner than physically possible (0.5 x ping) and inside the confirmation window. Pellets of one shot count once. |
| **miss** | The window closed with no damage, the connection looked healthy, at least one player was observable, nothing changed mid-flight. |
| **unconfirmed** | Cannot be told: ping spike / client stall in the window, respawn or weapon change mid-flight, target left, no observable target, two overlapping shots whose damage cannot be separated, or damage that arrived just after a "miss" was declared (the miss is re-labelled). |
| **not_fired** | The tool exposes a numeric ammo value that has *proven* it drops on shots (it is untrusted until it has dropped once) and it did not drop this time: cooldown / empty gun. Damage seen on such a click is not credited to it. |

`Hit%` = hits / (hits + misses). `Reg%` = hits / attempted.
**Scope:** with `scope = "auto"` and a Juju ragebot target set, only damage on that target can confirm a
hit; a shot that actually hits somebody else is therefore reported as a miss for this checker. Without a
ragebot target (or `scope = "all"`) damage on any observed player counts.

**Honest limit:** damage on a player is proven, *attribution to your shot is not*. If somebody else
damages the same player inside your window it counts as your hit. The window therefore follows your
ping (`1.5 x RTT + 2 x jitter + 50ms`, clamped 200ms-1500ms) to keep that risk small. See
`docs/SIM_RESULTS.md` for how often this happens under a synthetic model.

## Menu (tab "HitCheck")

Hit Checker: Enabled, Show HUD, Debug log, Live tab summary, Reset stats (momentary), Print report
(momentary), Max/Min window ms.
Auto Mode: Auto Mode DBS, Follow Juju auto, Scope (1 auto / 2 target / 3 all).
Only the documented element types (`toggle`, `slider`) are used.

## Auto Mode

Because no firing API is documented, Auto Mode is a **tracking** mode, not an automation:

`OFF` -> `ARMED` (no character, or a weapon other than the DBS is equipped) -> `ACTIVE` (DBS equipped,
connection healthy) -> `SUSPENDED` (ping spike/stall). Shots taken in ACTIVE/SUSPENDED are tagged
`auto`, others `manual`; compare the two in the report (`mode:auto` / `mode:manual`). The state is
published as flag `jhc_auto_state`. "Follow Juju auto" additionally treats a Juju flag as Auto Mode
ON: the flag is found by name (`get_flags()` containing "automode"/"auto") or set `host_auto_flag`.
Those flag names are not documented, so this is a heuristic.

## Exposed flags (read by other addons)

`jhc_version, jhc_loaded, jhc_shots, jhc_hits, jhc_misses, jhc_unconfirmed, jhc_not_fired,
jhc_hit_pct (-1 = n/a), jhc_auto_state, jhc_weapon`. The addon writes no other flags and calls no
mutating Juju function (checked by tests).

## Configuration

Edit `USER_CONFIG` at the top of the file, or set `getgenv().JHC_CONFIG = { ... }` before running it,
or set flags `jhc_cfg_<key>`. Every key, range and default is in `src/config.lua`; invalid values are
ignored with a message. Most useful: `scope`, `weapon_aliases` (the in-game tool name is
**unverified**; matching is letters-only substring, default `doublebarrel`, `dbarrel`, `dbsg`),
`window_min/max`, `window_rtt_mult`, `hud`.

## Known limits (read these)

* **Shot detection in practice.** Hood Customs guns do **not** fire `Tool.Activated` (melee does), so
  gun shots are counted from Juju's `on_player_bullet_fired`, which a two-client test showed carries
  only your own bullets; pellets within 50 ms count as one shot. The real tool name is `[DoubleBarrel]`.
* **Hit detection in practice.** In the live session every confirmed hit came from Juju's
  `on_local_bullet_confirmed` signal and none from `Humanoid.HealthChanged`, so on this game the native
  signal is what makes detection work; the health-based path is a fallback for builds without it. The
  confirmation arrived ~2.9x ping after the shot, so the window now learns from Juju-confirmed hit
  latencies (shown as `trusted=` in the report).
* **Live-observed, see `docs/LIVE_FINDINGS.md`.** The running Juju exposes signals the docs do not list; when
  `on_local_bullet_confirmed` exists it is used as the strongest hit evidence (`Juju-conf` in the HUD).
  Loaded from outside Juju's addon loader, `create_connection`/`create_section` do nothing: the addon then
  connects directly and runs without a menu.

* **Not verified live.** Everything was tested against mocks of Juju and Roblox on LuaJIT 2.1, never on
  Luau or in a real match (see `docs/TEST_REPORT.md`). Real Hood Customs may fire weapons without
  `Tool.Activated` (custom input, hold-to-fire) or use custom health instead of `Humanoid.Health`; then
  attempts or hits are under-counted. `Print report` shows what was actually found.
* `el:set_value` on elements returned by `create_element` is only shown on `find_element` results in the
  docs. It is used best-effort; if absent, the toggles may start visually off while the config is on, and
  the momentary buttons treat every click as a click.
* `os.clock` is assumed to be a wall-clock-rate monotonic clock. A one-time self-check compares it with
  `task.wait`; if they disagree the report prints `CLOCK WARNING`.
* Packet loss, server tick and whether the connection exploit is active are not observable through the
  documented API; none of them is claimed.
* Auto Mode does not fire, aim or choose targets.

## Calibrating on the real game

"Print report" lists, per bucket, measured hit latency (avg/min/max) and the ammo source found
(`ammo_source=value:Ammo (validated)` / `attr:...` / `none`), plus the average *hit latency / ping* ratio
(about 1.0-1.5 is expected if `get_ping` is a round trip). If hits cluster near your ping the defaults are
right; if "late" counts grow, raise `window_rtt_mult` or `window_floor`; if `unattributed_dmg` is
large, other players' damage is common and false hits are likelier - use `scope = "target"`.

## Development

```
python tools/build.py                                   # src/*.lua -> dist/jhc_hood_customs.lua
python tools/run_lua.py tests/run_all.lua               # 17 suites (auto-picks lua / OBS / Resolve runtime)
python tools/run_lua.py tests/run_all.lua --bundle dist/jhc_hood_customs.lua
python tools/mutation_check.py                          # breaks the code on purpose; the suite must notice
```

See `docs/TEST_REPORT.md` for results and what is simulated vs live (nothing here was run live).
