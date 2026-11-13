# Simulated latency study

**SIMULATION ONLY.** The real `Engine` and `Diag` modules were driven by a synthetic network model (every assumption is in the header of `tests/sim_eval.lua`). Ground truth exists only inside the simulation, so these numbers show how the classification logic behaves under the stated model. They are NOT measurements of Hood Customs or of any real connection.

Per cell: 3 seeds x 200 shots, true hit probability 50%, *other players'* damage on the same target at 0.3 events/s, server processing 25ms, jitter/spikes as named in the scenario.

Strategy B is the shipped default. Findings that drove the defaults:

* Fixed short windows lose hits on laggy links (recall collapses at 260ms+).
* Long windows (fixed 1500ms) keep recall but admit ~3x more unrelated damage as false hits. False hits are inherent to *any* window: another player's damage on the same target looks identical. Narrower windows lower them, which is why the window follows measured ping.
* A window that *learns* from observed hit latency (A) feeds on other players' damage and drifts long (feedback loop) -> disabled by default.
* Late-damage re-classification with an absolute/long grace (H) relabels many correct misses as unconfirmed; a grace relative to the window (B, 0.5x) keeps them.

```
## Clean ping readings (get_ping == true RTT)

RECALL: true hits reported as HIT (%)
  strategy \ scenario      40ms steady   90ms normal  160ms lagged    260ms poor     400ms bad   700ms awful
  fixed 250ms                    100.0          98.7          96.8          28.8           1.6           0.0
  fixed 600ms                    100.0         100.0          99.0          93.3          93.0          29.7
  fixed 1500ms                   100.0         100.0         100.0         100.0         100.0          97.4
  A learn_window=on              100.0         100.0         100.0         100.0         100.0          97.4
  B shipped default              100.0         100.0         100.0         100.0         100.0          97.4
  C old x2.0 +100 min250         100.0         100.0         100.0         100.0         100.0          97.4
  D tight x1.25 min120           100.0         100.0         100.0         100.0         100.0          97.4
  E causal ratio .8              100.0         100.0         100.0         100.0         100.0          96.5
  F causal floor off             100.0         100.0         100.0         100.0         100.0          97.4
  G no late grace                100.0         100.0         100.0         100.0         100.0          97.4
  H late grace x4                100.0         100.0         100.0         100.0         100.0          97.4

FALSE HITS: hit reported, shot did not hit (% of the shots that did NOT hit)
  strategy \ scenario      40ms steady   90ms normal  160ms lagged    260ms poor     400ms bad   700ms awful
  fixed 250ms                      5.6           5.2           4.5           3.8           1.7           0.0
  fixed 600ms                     15.3          15.0          14.3          13.6          11.5           6.6
  fixed 1500ms                    32.1          31.7          31.0          30.7          28.6          24.0
  A learn_window=on                6.3           8.4          17.8          25.8          26.8          23.7
  B shipped default                4.9           4.5           8.4          11.5          19.2          21.6
  C old x2.0 +100 min250           5.6           7.7          11.1          18.1          22.6          24.0
  D tight x1.25 min120             2.4           4.2           7.7          10.5          17.1          20.9
  E causal ratio .8                4.9           4.2           7.7           8.7          13.9          18.1
  F causal floor off               5.9           5.9          10.5          14.3          24.0          31.0
  G no late grace                  4.9           4.5           8.4          11.5          19.2          21.6
  H late grace x4                  4.9           4.5           8.4          11.5          19.2          21.6

FALSE MISSES: miss reported, shot did hit (count, after late-damage re-classification)
  strategy \ scenario      40ms steady   90ms normal  160ms lagged    260ms poor     400ms bad   700ms awful
  fixed 250ms                        0             0             0             0           114            42
  fixed 600ms                        0             0             0             0             2            60
  fixed 1500ms                       0             0             0             0             0             0
  A learn_window=on                  0             0             0             0             0             0
  B shipped default                  0             0             0             0             0             0
  C old x2.0 +100 min250             0             0             0             0             0             0
  D tight x1.25 min120               0             0             0             0             0             0
  E causal ratio .8                  0             0             0             0             0             0
  F causal floor off                 0             0             0             0             0             0
  G no late grace                    0             0             0             0             0             5
  H late grace x4                    0             0             0             0             0             0

UNCONFIRMED of all shots (%)
  strategy \ scenario      40ms steady   90ms normal  160ms lagged    260ms poor     400ms bad   700ms awful
  fixed 250ms                      2.0           5.0           6.7          44.2          45.7          84.7
  fixed 600ms                      3.0           5.2           6.3          10.5           9.0          31.7
  fixed 1500ms                     7.0           8.7           9.0           9.8           8.8           9.2
  A learn_window=on                1.2           3.7           4.8          10.2           8.8           9.3
  B shipped default                1.2           4.2           4.5           7.8           6.0          10.2
  C old x2.0 +100 min250           2.0           4.2           6.5           7.0           9.3           9.2
  D tight x1.25 min120             0.7           3.2           4.5           7.8           5.7           9.7
  E causal ratio .8                1.2           4.2           4.5           8.2           6.5          11.0
  F causal floor off               1.2           4.2           4.5           8.0           5.7           9.2
  G no late grace                  0.0           2.5           3.0           4.3           2.8           2.2
  H late grace x4                  5.0           8.2          10.0          15.0          14.2          16.0

mean confirmation window (ms)
  strategy \ scenario      40ms steady   90ms normal  160ms lagged    260ms poor     400ms bad   700ms awful
  fixed 250ms                      250           250           250           250           250           250
  fixed 600ms                      600           600           600           600           600           600
  fixed 1500ms                    1500          1500          1500          1500          1500          1500
  A learn_window=on                231           316           737          1378          1437          1498
  B shipped default                200           222           373           603           926          1432
  C old x2.0 +100 min250           250           320           513           791          1184          1498
  D tight x1.25 min120             120           196           328           528           822          1320
  E causal ratio .8                200           222           373           603           924          1431
  F causal floor off               200           222           374           604           927          1434
  G no late grace                  200           222           373           603           926          1432
  H late grace x4                  200           222           373           603           926          1432

## Noisy ping readings (get_ping off by up to +/-30%)

RECALL: true hits reported as HIT (%)
  strategy \ scenario      40ms steady   90ms normal  160ms lagged    260ms poor     400ms bad   700ms awful
  fixed 250ms                    100.0          98.7          96.8          28.4           2.9           0.0
  fixed 600ms                    100.0         100.0          99.0          93.3          93.0          29.7
  fixed 1500ms                   100.0         100.0         100.0         100.0         100.0          97.4
  A learn_window=on              100.0         100.0         100.0         100.0         100.0          97.4
  B shipped default              100.0         100.0         100.0         100.0         100.0          97.4
  C old x2.0 +100 min250         100.0         100.0         100.0         100.0         100.0          97.4
  D tight x1.25 min120           100.0         100.0         100.0         100.0         100.0          97.4
  E causal ratio .8              100.0         100.0         100.0         100.0          99.4          96.5
  F causal floor off             100.0         100.0         100.0         100.0         100.0          97.4
  G no late grace                100.0         100.0         100.0         100.0         100.0          97.4
  H late grace x4                100.0         100.0         100.0         100.0         100.0          97.4

FALSE HITS: hit reported, shot did not hit (% of the shots that did NOT hit)
  strategy \ scenario      40ms steady   90ms normal  160ms lagged    260ms poor     400ms bad   700ms awful
  fixed 250ms                      5.6           5.2           3.8           3.8           2.1           0.0
  fixed 600ms                     15.3          15.0          13.6          13.6          11.8           6.6
  fixed 1500ms                    32.1          31.7          30.7          30.7          28.6          24.4
  A learn_window=on                6.3           8.4          17.8          26.5          26.5          24.0
  B shipped default                4.9           5.2           8.4          13.6          19.2          22.3
  C old x2.0 +100 min250           5.6           8.0          11.1          18.8          23.7          24.4
  D tight x1.25 min120             2.4           4.9           7.3          10.8          16.7          21.6
  E causal ratio .8                4.9           4.9           8.4          11.1          15.3          19.2
  F causal floor off               5.9           6.6          11.1          16.4          24.0          31.0
  G no late grace                  4.9           5.2           8.4          13.6          19.2          22.3
  H late grace x4                  4.9           5.2           8.4          13.6          19.2          22.3

FALSE MISSES: miss reported, shot did hit (count, after late-damage re-classification)
  strategy \ scenario      40ms steady   90ms normal  160ms lagged    260ms poor     400ms bad   700ms awful
  fixed 250ms                        0             0             2             2           110            49
  fixed 600ms                        0             0             0             1             5            58
  fixed 1500ms                       0             0             0             0             0             0
  A learn_window=on                  0             0             0             0             0             0
  B shipped default                  0             0             0             0             0             0
  C old x2.0 +100 min250             0             0             0             0             0             0
  D tight x1.25 min120               0             0             0             0             0             0
  E causal ratio .8                  0             0             0             0             0             2
  F causal floor off                 0             0             0             0             0             0
  G no late grace                    0             0             0             0             0             3
  H late grace x4                    0             0             0             0             0             0

UNCONFIRMED of all shots (%)
  strategy \ scenario      40ms steady   90ms normal  160ms lagged    260ms poor     400ms bad   700ms awful
  fixed 250ms                      2.0           4.7           6.2          43.7          47.7          83.2
  fixed 600ms                      3.0           4.8           6.2          10.3           9.3          33.2
  fixed 1500ms                     7.0           8.5           9.0           9.8           9.5           9.8
  A learn_window=on                1.2           3.7           5.2          10.2           9.8          10.0
  B shipped default                1.2           3.8           4.8           7.5           7.3          10.5
  C old x2.0 +100 min250           2.0           3.8           6.2           7.7           8.2           9.8
  D tight x1.25 min120             0.7           3.3           4.2           7.7           7.5          10.3
  E causal ratio .8                1.2           3.8           4.8           8.0           8.0          10.7
  F causal floor off               1.2           3.8           4.7           7.3           6.8           9.2
  G no late grace                  0.0           2.2           2.7           4.3           3.8           3.3
  H late grace x4                  5.0           7.5          10.7          14.5          15.3          17.2

mean confirmation window (ms)
  strategy \ scenario      40ms steady   90ms normal  160ms lagged    260ms poor     400ms bad   700ms awful
  fixed 250ms                      250           250           250           250           250           250
  fixed 600ms                      600           600           600           600           600           600
  fixed 1500ms                    1500          1500          1500          1500          1500          1500
  A learn_window=on                231           333           809          1391          1440          1497
  B shipped default                200           237           397           642           961          1435
  C old x2.0 +100 min250           250           337           539           831          1211          1498
  D tight x1.25 min120             122           212           351           567           857          1346
  E causal ratio .8                200           237           397           642           959          1434
  F causal floor off               200           237           398           643           964          1436
  G no late grace                  200           237           397           642           961          1435
  H late grace x4                  200           237           397           642           961          1435
```
