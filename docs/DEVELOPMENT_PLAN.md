# Development plan

Scope decision (see API_REFERENCE.md): build everything the documented Juju API plus standard
Roblox signals can honestly support; document the rest as limitations.

## Architecture (source in `src/`, shipped as one bundled file in `dist/`)

```
util      ring buffers, stats helpers, connection Bag (dedupe + cleanup), safe calls
config    defaults, schema validation, clamping, flag overrides, runtime set()
host      adapter over juju/game/task/Drawing + capability probe + read-only guard
diag      ping/jitter/spike/stall tracking, adaptive confirmation window, desync gap
weapon    weapon identification (Double Barrel Shotgun aliases), pure functions
engine    Hit Checker core: shot -> outcome state machine, statistics (pure, no Roblox deps)
automode  Auto Mode state machine (OFF / ARMED / ACTIVE / SUSPENDED)
world     Roblox glue: local character + tool tracking, target Humanoid tracking, sampler
ui        Juju menu (toggle/slider only), optional Drawing HUD, report, flag export
main      composition, init-failure handling, duplicate-load guard, unload
```

The engine is pure (time and timers injected), so it is deterministic under test and cannot be
broken by Roblox API differences. Everything Roblox-specific is isolated in `world`/`host`.

## Outcome model (the heart of the Hit Checker)

Each shot attempt ends in exactly one outcome:

| Outcome | Condition |
|---|---|
| `hit` | replicated damage on an observable candidate after the causal floor (`ratio * ping`), inside the adaptive window |
| `miss` | window elapsed, no damage, >=1 observable candidate, connection healthy, no context change, no overlap ambiguity, (fire not disproved) |
| `unconfirmed` | cannot tell: degraded connection / ping spike / stall, respawn or weapon change mid-window, target lost, no observable target, ambiguous overlapping shot, or damage arrived late (miss re-classified) |
| `not_fired` | ammo source exists and shows no decrement (cooldown/empty) |
| pending | in flight |

Invariant (tested): `attempted = hit + miss + unconfirmed + not_fired + pending`.

Window = clamp(rtt_mult * RTT_ref + jitter_mult * jitter + floor, min, max)
with RTT_ref = max(median of recent pings, latest ping), jitter = median |successive difference|
(defaults 1.5 / 2.0 / 50ms, clamp 200ms..1500ms). An optional `learn_window` term (p95 of observed hit
latency) exists but is OFF: the simulation showed it feeds on other players' damage (see
SIM_RESULTS.md). A miss is only re-labelled `unconfirmed` by late damage within 0.5 x window after
its deadline (a long/absolute grace relabelled many correct misses in the simulation).
Pellets from one shot are coalesced into one damage burst, so a shotgun shot counts once.

## Auto Mode

No documented firing API -> Auto Mode does **not** fire. It is a tracking mode that:
tracks whether the Double Barrel Shotgun is equipped, whether the character/connection is healthy,
tags every shot `auto` or `manual` so the two can be compared, reads Juju's `ragebot` flag and
optionally a user-named host auto flag, and exposes state through `jhc_auto_state`.
States: OFF -> ARMED (no character / other weapon) -> ACTIVE -> SUSPENDED (degraded connection).

## Stages

1. Docs audit + API reference (done)
2. Core modules: util, config, host, diag, weapon, engine, automode
3. Roblox glue + UI + main
4. Test harness (strict Juju mock, Roblox mock, virtual clock) and the 16 required test areas
5. Latency simulation to compare window strategies with measured numbers
6. Run, fix, re-run (regression), performance review, review of every source file
7. Bundle `dist/jhc_hood_customs.lua`, re-run tests against the bundle, final report

## Test environment

No Lua interpreter is installed. `tools/run_lua.py` loads an existing Lua 5.1 DLL
(OBS `lua51.dll`, DaVinci Resolve `lua5.1.dll`) through ctypes, read-only. Source is written in the
common subset of Lua 5.1 / LuaJIT / Luau (no `continue`, `+=`, type annotations). **Luau itself is
not available, so Luau-specific parsing is unverified.** No live Roblox/Juju test is run by the
automated suite; all results are labelled SIMULATED.
