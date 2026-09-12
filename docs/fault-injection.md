# Host fault-injection evidence

Run date: 2026-09-12. Ten deterministic scenarios exercised the production
`cue_session.c`, wire codec, and kernel on a Linux x86-64 host. The experiment
compares decoded decision fields against a separate baseline kernel state.
It does not execute the Swift `PicoStreamer`, BLE radio, GPIO, or actuator.

All ten scenarios met their explicit expectations. This includes documented
blind spots; it does **not** mean all injected faults were prevented or detected.
The [ordinary run](evidence/fault-injection-host.json) and
[sanitized run](evidence/fault-injection-sanitized.json) contain compiler flags,
source hashes, isolated mutation details, and scenario counts. The base revision
is recorded with a dirty-tree flag because this change was under development;
the source hashes identify the exact tested files.

## Results

| Scenario | Rejected frames | Decision mismatches | Actuation requests | Compared reports | Interpretation |
| --- | --- | --- | --- | --- | --- |
| Clean control | 0 | 0 | 1 | 5 | Baseline agreement |
| Dropped middle step | 1 | 0 | 0 | 5 | Next write exposes gap; catch-up restores decisions without stale cue |
| Duplicate step | 0 | 0 | 1 | 6 | Identical cached report; no second actuation request |
| Reordered steps | 1 | 0 | 1 | 5 | Out-of-order write rejected; ordered retry recovers |
| MCU session reset | 1 | 0 | 1 | 7 | STEP rejected; resume says NOT_RIDING; full silent catch-up recovers |
| Truncated frame | 1 | 0 | 1 | 5 | Rejected without state mutation; valid retry recovers |
| Unknown flag | 1 | 0 | 1 | 5 | Rejected without state mutation; valid retry recovers |
| Dropped initial non-cue step | 0 | 0 | 1 | 4 | Loss not exposed by sequencing or decisions in this fixture |
| Lost final report | 0 | 0 | 1 | 4 | Zero mismatches with incomplete comparison coverage |
| Same-size kernel mutation | 0 | 1 | 1 | 1 | Size check passes; mismatch observed after actuation was requested |

Counts include retried and catch-up reports, not unique inputs. An actuation
request is a boolean returned by the session, not a measured sound or GPIO edge.
The reset case's one actuation request occurred before the reset. The duplicate
case tests sender retry and cached-report behavior, not phone-side notification
deduplication. Recovery is explicitly driven by the harness; automatic phone
reconnect behavior is outside this experiment.

## Detection boundaries

- A dropped middle step is exposed by the first subsequent noncontiguous write;
  the fixture places it 1,000 ms later on its synthetic sample clock. Reordered,
  malformed and post-reset writes are refused during that handler call.
  No wall-clock or over-the-air detection latency was measured.
- The first sequence number is unrestricted by the current session contract.
  Losing the initial non-cue sample therefore produces four matching reports
  and no sequence error. This is a demonstrated coverage limitation, not evidence
  that all initial losses remain behaviorally invisible.
- The final missing report is an omission, not a mismatch. There is no subsequent
  report in this experiment to expose it. Coverage must accompany divergence counts.
- The isolated mutant changes `tte_s > effective_max_notice_s` to
  `tte_s > effective_max_notice_s + 1`. At 21 s lead, the baseline says TOO_EARLY
  but the candidate requests HEAD_UP. Its state layout remains unchanged, so
  SESSION_ACK's size field cannot identify the behavioral drift. The host detects
  it at the first compared report, after the session has requested actuation.

The mutation is created only inside a temporary build directory; production
kernel source is not changed. The harness links an ordinary shadow kernel and a
separately named mutant used only by the candidate session.

## Reproduce

```sh
python3 tools/cue-fault-injection/run.py --output /tmp/cue-fault-host.json
ASAN_OPTIONS=detect_leaks=0 python3 tools/cue-fault-injection/run.py \
  --sanitize --output /tmp/cue-fault-sanitized.json
make test
```

The ordinary campaign is included in `make test`. AddressSanitizer and
UndefinedBehaviorSanitizer completed successfully. LeakSanitizer initially
failed because this execution environment could not inspect process threads;
the recorded sanitizer run explicitly disables leak detection. No leak-check
success is claimed. No lint/format gate exists in this repository.

These are ten directed host scenarios, not statistical coverage, exhaustive
state-space exploration, field re-verification, or on-target certification.
Physical BLE loss/reconnect, phone receiver deduplication, audible delivery,
and field fault incidence still require separate evidence.

## Field corpus status and verification command

The original 23-trace corpus was unavailable in the checkout. Searches for
uploaded ride/trace files and inspection of the accessible archive's trace
directory found no field corpus. Running the verifier against `rides/` returned
`blocked_missing_corpus`; no historical field figure was re-verified.

On the machine holding the original exports, use a new output directory:

```sh
python3 tools/cue-field-verify/verify.py /absolute/path/to/rides \
  --corpus-kind field --expected-traces 23 \
  --output /absolute/path/to/new-verification-output
```

Include `*-trace.json`, `*-pico.json`, and `*-latency.json`. If the corpus has
grown, use its known count instead of 23. Corpus kind is explicitly caller-declared;
the script cannot prove that supplied traces came from a physical ride.

The script snapshots and hashes input bytes, forces a fresh replay build,
verifies every trace, runs the corrected ablations, and records aggregation
output. It recomputes sidecar comparisons from decision fields and checks stored
flags/counters, rejecting disagreements and duplicate sequences. Missing reports
are counted explicitly. Orphan-report totals and physical actuation flags cannot
be independently proved from these sidecars. No sidecars means no shadow/delivery
re-verification, even when replay passes. Logs may contain private ride identifiers;
keep this output private until reviewed. Raw trace data is not published.

The command was exercised successfully on the six synthetic demo traces, and
regression tests cover missing input, inconsistent sidecar counters, hidden
decision mismatches, partial reports and duplicate sequences. Those tests do
not substitute for the pending field run.
