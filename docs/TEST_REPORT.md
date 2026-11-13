# Test report (v1.0.0)

**Everything below is SIMULATED. Nothing was run in a live Roblox / Juju session.** The environment is a
strict mock of the documented Juju API plus mocks of the Roblox instances/signals the addon uses
(`tests/mock.lua`). It enforces the documented signatures and raises on anything undocumented, but it
is still my reading of the docs and of standard Roblox behaviour, not the real game.

## Runtime used

No Lua interpreter was installed. `tools/run_lua.py` loads an existing Lua 5.1 DLL read-only through
`ctypes` (nothing downloaded or installed): OBS Studio's `lua51.dll` (**LuaJIT 2.1.1724512491**) and
DaVinci Resolve's `lua5.1.dll` (**LuaJIT 2.1.0-beta3**). So: two LuaJIT builds. **Not run on Luau**
(Roblox's dialect) or on PUC Lua. The source sticks to the common subset (no `continue`, `+=`, type
annotations, `goto`), but Luau parsing/semantics are unverified.

## Results

| Configuration | Result |
|---|---|
| `src/` on LuaJIT 2.1.1724 | 280 / 280 |
| `src/` on LuaJIT 2.1.0-beta3 | 280 / 280 |
| `dist/jhc_hood_customs.lua` (shipped single file) on LuaJIT 2.1.1724 | 280 / 280 |
| `dist/jhc_hood_customs.lua` on LuaJIT 2.1.0-beta3 | 280 / 280 |
| Mutation check (`tools/mutation_check.py`): deliberate breakages detected | 71 / 71 |

```
 01 Addon initialization                  14     10 Event handling                 14
 02 Juju API compatibility                 8     11 Respawn handling               12
 03 Hit detection                         14     12 Weapon switching                9
 04 Miss detection                        16     13 Configuration loading          16
 05 Hit statistics                         9     14 UI functionality               17
 06 Weapon detection                      15     15 Error recovery                 15
 07 Double Barrel Shotgun                 12     16 Performance and stability       9
 08 Auto Mode state handling              14     17 Latency study (SIMULATED)      12
 09 Connection diagnostics                17     18 Review regressions             22
                                                 19 Loader script                   8
                                                 20 Live findings                   8
                                                 21 Juju native confirmation       11
                                                 22 Window follows confirmed lat.   8
```

Suites 01-16 map one-to-one onto the 16 test areas requested. 17 is the latency study, 18 holds one
regression test per defect found by the independent review, 19 runs `loader.lua` against the mocks
(success, `getgenv().JHC_CONFIG`, `request()` fallback, no Juju, download failure, wrong payload,
compile error, start error). 20 reproduces behaviour seen in the first live run (`create_connection`/
`create_section` returning nil), 21 covers Juju's native `on_local_bullet_confirmed` signal.

Performance (simulated clock, real CPU): the engine handles a shot+hit cycle in ~3-5 microseconds;
5000 end-to-end shots changed the Lua heap by -35 to -63 KB (no growth); idle cost is one `get_ping` +
one task wake per second; with the addon disabled it is zero; connection count is constant over 100
respawns, 100 weapon switches and 40 player joins/leaves.

## How much the tests can be trusted

* **Mutation check.** 71 deliberate one-line breakages of `src/` (remove the causal floor, stop
  releasing a connection key, let a hit through without damage, ...). The first run caught 32 of 38;
  the 6 survivors were gaps in my tests (and one equivalent mutant) and got new tests. The list then
  grew with each round of findings (review, live run, trusted-latency window) to 71, and three more
  survivors along the way were weak tests that were tightened. Final: 71 / 71.
* **Vacuous tests found and fixed.** The Drawing mock initially never counted text writes, so the
  "HUD only rewrites changed lines" test passed for the wrong reason; the memory test was measuring the
  mock's own call log. Both were corrected (the HUD test now also asserts the mock saw writes).
* **Independent review.** A fresh reviewer, given only the code and the docs, found 12 issues; 11 were
  valid and fixed, 1 was partly wrong (the pending invariant *is* cross-checked against the real
  pending list by the test helper) but still led to a report-level invariant check.

## Defects found and fixed (all real, all reproducible before the fix)

From my own tests: `start_sampler` left its "on" flag set after a failed `task.spawn`; initial
`set_value` calls fired the menu handlers before the world existed; the ammo-name heuristic matched
"Damage" (contains "mag"); every enemy respawn leaked a `Humanoid.Died` connection (key/prefix
mismatch); slider bounds reset each other.

From the latency simulation: the *learned* window fed on other players' damage and drifted to the
maximum (identical to a fixed 1500 ms window) -> off by default; the absolute 2 s "late damage" grace
relabelled many correct misses -> now 0.5 x window; p95/mean-jitter made rare spikes inflate every
window -> median-based.

From the independent review: damage bursts from other players could swallow the real damage of a shot
fired right after them (-> false miss); burst chains were unbounded; constant-named values
("BulletSpeed") or never-changing "Ammo" values could turn all misses into `not_fired`; a click that
showed no fire could be credited with someone else's damage; a window shorter than the causal floor
made every shot a "miss"; damage in the frame between deadline and expiry was lost; nothing sampled the
ping at expiry; menu assumptions about `set_value`/creation callbacks; stale `jhc_loaded`; late local
Humanoid; a leaked half-configured Drawing object; console flooding by a failing handler. A one-time
clock self-check (`os.clock` vs `task.wait`) was added because Luau's `os.clock` semantics could not
be verified here.

## Simulated latency study (summary; full tables in `docs/SIM_RESULTS.md`)

Synthetic network: 40-700 ms links with jitter and spikes, 50% true hit rate, other players dealing
damage to the same target at 0.3 events/s. 3 seeds x 200 shots per cell, ground truth known only to
the simulation. Shipped default vs alternatives (clean ping readings):

| Link | 40 ms | 90 ms | 160 ms | 260 ms | 400 ms | 700 ms |
|---|---|---|---|---|---|---|
| default: true hits reported as HIT | 100% | 100% | 100% | 100% | 100% | 97% |
| default: false hits (of non-hitting shots) | 4.9% | 4.5% | 8.4% | 11.5% | 19% | 22% |
| fixed 1500 ms window: false hits | 32% | 32% | 31% | 31% | 29% | 24% |
| fixed 250 ms window: true hits reported | 100% | 99% | 97% | 29% | 2% | 0% |
| default mean window | 200 ms | 222 ms | 373 ms | 603 ms | 926 ms | 1432 ms |

Reading it honestly: no window can remove false hits, because another player's damage on the same
target is indistinguishable from yours; the window only controls how often it happens. The numbers
show the *relative* behaviour of the strategies under this model, not Hood Customs.

## Live smoke test (one real session, first-hand)

Run through a connected Potassium client; the bundle was loaded from this repo at a pinned commit. Details
in `docs/LIVE_FINDINGS.md`. In short: the addon loaded and tracked real `Tool.Activated` shots, ping,
targets and the Juju `auto_mode` flag; it exposed two real defects the mocks had hidden
(`create_connection`/`create_section` returning nil outside an addon context) which were fixed and
re-verified live; and it revealed Juju's undocumented native bullet signals, now used as hit evidence.
**Not** verified live: the menu under Juju's real addon loader, the on-screen HUD, melee/ammo signals.

The second live run (107 tracked attempts, knife) produced the measurement that drove the last change:

* **All 14 hits came from Juju's `on_local_bullet_confirmed`; `Humanoid.HealthChanged` produced none**
  (`corroborated=0`). On this game the health-based inference the addon was originally built on may
  not fire at all for another player's damage. The native signal is what makes hit detection work here.
* **Confirmation latency was ~2.9 x ping** (112-226 ms at 52 ms ping), i.e. wider than the shipped
  window (1.5 x RTT + 50 ms = 200 ms floor). The slowest confirmations only landed because of the
  late-damage grace, and anything slower would have been reported as a miss.
* Fix: latencies of hits **Juju itself attributed to the local bullet** now steer the window
  (suite 22). These cannot be another player's damage, so the feedback loop that keeps `learn_window`
  off by default does not apply. A test reproduces the live latency spread and shows that without
  this, 2 of 8 real hits at 212/226 ms are reported as unconfirmed-late instead of hits.

## What was NOT tested

* The automated suite itself is entirely simulated. Live coverage is limited to the smoke test above;
  in particular the Double Barrel Shotgun was only seen being *equipped* (`[DoubleBarrel]`), and no
  shot of mine was fired.
* Luau parsing/semantics; real `Drawing`, `task`, `os.clock`.
* Packet loss, server tick, and the connection exploit itself: not observable through the documented
  API, so there is nothing to test (see `docs/API_REFERENCE.md` section 4).
* "Auto Mode reliability" in the sense of maximizing hit registration: Auto Mode here does not fire or
  aim, so there is no firing behaviour to optimise; the state machine and tagging are tested.
