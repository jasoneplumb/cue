# Regenerated synthetic ablation results

Generated 2026-09-12 from base commit `66702ede6c37c6e83175a50aece0f5ec66f497bd`
with the exact-verification fix in this change. Commands:

```sh
make demo-corpus
python3 tools/cue-ablation/ablate.py demo-rides
python3 tools/cue-results/aggregate.py demo-rides
```

These are synthetic mechanism checks, not new field observations. The generator
uses the kernel to author its golden decisions; this demonstrates a reproducible
pipeline, not an independent oracle for policy correctness. No private ride
traces or delivery sidecars were available for regeneration.

## Ablations

corpus: 6 traces, 23 recorded HEAD_UP cues (baseline verified against all recorded decisions)

| Variant | Cues | Lead s min/med/max | In 5–20 s window | Top suppressions |
| --- | --- | --- | --- | --- |
| baseline | 23 | 19 / 20 / 20 | 23/23 | INSIDE_EVENT 1,363, TOO_EARLY 893, ALREADY_CUED 412 |
| no_memory | 23 | 19 / 20 / 20 | 23/23 | INSIDE_EVENT 1,363, TOO_EARLY 893, ALREADY_CUED 412 |
| no_thresholds | 23 | 19 / 20 / 20 | 23/23 | INSIDE_EVENT 1,363, TOO_EARLY 893, ALREADY_CUED 412 |
| every_zone | 23 | 41 / 48 / 76 | 0/23 | ALREADY_CUED 1,436, INSIDE_EVENT 1,363 |
| distance_gate | 23 | 9 / 20 / 64 | 15/23 | INSIDE_EVENT 1,363, TOO_EARLY 643, ALREADY_CUED 589 |

| Variant | Changed observation decisions | Changed cue timestamps |
| --- | --- | --- |
| baseline | 0 | 0 |
| no_memory | 0 | 0 |
| no_thresholds | 0 | 0 |
| every_zone | 1047 | 46 |
| distance_gate | 509 | 36 |


## Full suppression histograms

```text
  baseline: INSIDE_EVENT=1,363, TOO_EARLY=893, ALREADY_CUED=412, TOO_LATE=131
  no_memory: INSIDE_EVENT=1,363, TOO_EARLY=893, ALREADY_CUED=412, TOO_LATE=131
  no_thresholds: INSIDE_EVENT=1,363, TOO_EARLY=893, ALREADY_CUED=412, TOO_LATE=131
  every_zone: ALREADY_CUED=1,436, INSIDE_EVENT=1,363
  distance_gate: INSIDE_EVENT=1,363, TOO_EARLY=643, ALREADY_CUED=589, TOO_LATE=204
```

Changed observation decisions compare every emitted decision field, keyed by
ride and timestamp, against the baseline `--print` stream. This includes
suppression reasons and calculated lead time. Changed cue timestamps count a
removed, added, or field-changed HEAD_UP once at each affected timestamp. A cue
moved from one time to another contributes two changed timestamps, not two
physical warnings. Neither metric is a safety or perceptibility outcome.

All 23 every-zone cues move (46 affected timestamps). The distance gate affects
36 cue timestamps despite retaining 23 cues. Memory and threshold/cooldown
removal change no emitted observation decisions in this synthetic corpus.
The distance variant has 8/23 cues outside the calculated 5–20 s window.
These results do not reproduce the historical field cue-count increase.

## Corpus and delivery aggregation

Zero delivery records below mean no delivery evidence exists in the demo;
they do not establish successful delivery or zero field failures.

```text
== corpus ==
traces: 6 (6 with motion)
kernel steps (samples): 3550
distance_km: 13.3
HEAD_UP cues: 23
grades: 0 across 0 rides — useful=0, false_alarm=0, too_late=0, too_early=0, unrecognized=0
== watch delivery (latency sidecars) ==
dispatches: 0, delivered live: 0, queued (undelivered): 0, other undelivered: 0
== phone<->pico shadow contract (pico sidecars, RFC 0006) ==
instrumented rides: 0
steps logged: 0, shadow-compared: 0, divergences: 0, orphan reports: 0
buzzer actuations: 0
```

## Input hashes (SHA-256)

```text
fe67f8619a1b22f438775ebe962d1a78a918d52a45412cdf9f2053f6bd0f23fe  demo-ride-00-trace.json
0ef7fb369896c43632d9b6013dd84c7166055b98b224720e3b319618a708df3a  demo-ride-01-trace.json
83f6d91cf187c2d30e5d5e78fdaa9a44fd87b92c1cc1e3bd78e5169333dfece5  demo-ride-02-trace.json
1fdfc2a07a9846a6caa92e446b4e522b8661c69906e34fcbae1f99fdc99a8afe  demo-ride-03-trace.json
f653303040f6bc3cc8499590c82fd115357ff194211ce5ba2880ae9b878b302e  demo-ride-04-trace.json
51c7e4c9c568a34c884be578e8de2eebe208f6b288bce84873f3ce1b157bf35c  demo-ride-05-trace.json
```
