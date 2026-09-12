# Field corpus re-verification

Verified 2026-09-12 against the uploaded private corpus. All 23 traces pass
normal replay verification before the corrected ablation sweep prints tables.
The corpus contains 57,783 samples, 42 recorded HEAD_UP cues, and 88.1 km of
speed-integrated distance (19 traces with motion).

[Aggregate evidence](evidence/field-reverification-summary.json) records the
compiler, replay binary and source hashes, a filename-free corpus digest, and
regenerated tables. The tested source tree is identical to remote revision
`dd8a7db25522734de1dbec614f66113c69d80dcb`. Raw exports, GPS coordinates,
ride names/identifiers and per-ride verification logs remain outside Git.

## Regenerated ablations

| Variant | Cues | Lead s min/med/max | In 5–20 s window | Top suppressions |
| --- | --- | --- | --- | --- |
| baseline | 42 | 12 / 15 / 20 | 42/42 | TOO_SLOW 21,196, TOO_EARLY 6,733, INSIDE_EVENT 1,909 |
| no_memory | 42 | 12 / 15 / 20 | 42/42 | TOO_SLOW 21,196, TOO_EARLY 6,733, INSIDE_EVENT 1,909 |
| no_thresholds | 42 | 12 / 15 / 20 | 42/42 | TOO_SLOW 21,196, TOO_EARLY 6,733, INSIDE_EVENT 1,909 |
| every_zone | 83 | 34 / 226 / 1748 | 0/83 | TOO_SLOW 21,196, ALREADY_CUED 7,589, INSIDE_EVENT 1,899 |
| distance_gate | 41 | 6 / 19 / 73 | 24/41 | TOO_SLOW 21,196, TOO_EARLY 6,488, INSIDE_EVENT 1,906 |

| Variant | Changed observation decisions | Changed cue timestamps |
| --- | --- | --- |
| baseline | 0 | 0 |
| no_memory | 16 | 0 |
| no_thresholds | 0 | 0 |
| every_zone | 7114 | 125 |
| distance_gate | 820 | 83 |

Memory removal changes 16 reason codes and no cue timestamps. Threshold and
cooldown removal changes no emitted decisions. Removing the notice window as
well increases cues from 42 to 83, with none in the calculated 5–20 s window.
The distance gate yields 41 cues, 17 outside that window. Its 83 changed cue
timestamps count additions/removals/changes at timestamps, not 83 unique cues.
These are fixed-trajectory counterfactual replays, not measured rider responses.

## Comparison and delivery coverage

Eight Pico sidecars contain 11,301 logged steps: 11,300 compared and one
uncompared tail record. Recomputing all four decision fields finds zero
mismatches. Stored comparison counters and divergence flags agree; reported
orphan count is zero. All eight Pico and all 23 latency sidecars have matching
trace filenames. This confirms recorded comparison coverage, not independent
firmware identity, physical output, or the cause of the missing tail report.

Watch exports contain 49 dispatches: 27 marked delivered live and 22 queued
without live delivery. Among the 27, 18 have a play verdict, four a duplicate
verdict, and five predate verdict recording. Exported latency has median 542 ms
(range 25–2,890 ms, n=27). These transport/verdict counts do not prove perception.
The 49 dispatches and 42 kernel cues are different denominators.

Pico exports mark 15 actuations; 13 include microsecond delay values
(138–173 µs, median 147 µs). No GPIO or sound was independently measured here.
Rider grades total 33: 17 useful, seven too late, seven unrecognized, two too
early, and zero false alarms. These descriptive grades do not establish a
controlled rider-benefit effect or a general false-alarm rate.

## Implications and reproducibility

This closes the missing-corpus replay gap and reproduces the historical
aggregate numbers. Together with the [host fault campaign](fault-injection.md),
it supports an engineering experience report on execution consistency,
comparison coverage and failure boundaries. Shared-kernel agreement cannot
prove the shared policy is correct; the fault campaign shows both undetected
coverage loss and divergence reported after an actuation request.

The raw corpus remains private. Holders can run the command in
[fault-injection.md](fault-injection.md#field-corpus-status-and-verification-command)
on a new output directory. A public reader can inspect the aggregate evidence
and reproduce host faults and synthetic ablations, but cannot independently
reproduce these field results without access to the private corpus.
