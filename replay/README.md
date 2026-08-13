# replay — Deterministic Trace Replay Harness (FR-010)

Feeds a recorded ride trace through the cue-policy kernel
(`kernel/cue_policy.h`) and verifies the kernel reproduces the trace's
recorded cue decisions exactly (NFR-003). Divergence between live and replay
decisions is a bug — this harness is the detector.

## Usage

```bash
make -C replay test                              # build + replay all checked-in traces
replay/build/replay_cli <trace.json>             # verify one trace (exit 0/1/2)
replay/build/replay_cli --print <trace.json>     # emit kernel decisions as JSON
replay/build/replay_cli --stats <trace.json>     # verify, then print cue-timing metrics
```

Exit codes: `0` every recorded decision matches, `1` divergence (details on
stdout), `2` malformed trace or usage error.

`--print` runs the same replay but prints the kernel's decision for every
sample that carries route-event observations, formatted as a `cue_decisions`
array — paste it into a new trace to author fixtures. The input trace must
still be complete per the schema; when authoring from scratch, start with
`"cue_decisions": []` and fill it from the `--print` output.

`--stats` verifies exactly like the default mode — a diverging trace still
prints its divergences and exits 1, with no stats — then prints measurement
metrics (spec §13; §14 "cue timing lands roughly 5–15 seconds before the
segment"):

- every `HEAD_UP` with its `event_id`, `t_ms`, and `lead_time_s`;
- lead-time min / median / max (integer math; the median is the lower-middle
  element of the sorted lead times) and how many cues land inside the
  configured notice window `[min_notice_s, max_notice_s]`;
- a histogram of suppressed (`NONE`) decisions by `reason_code`, using the
  symbolic `CUE_REASON_CODE_*` names from `kernel/cue_policy.h`. Only
  decisions at samples carrying observations are counted — a `NO_EVENT`
  decision on an observation-free sample is the kernel idling, not a
  suppressed cue;
- review-outcome counts (`useful` / `false_alarm` / `too_late` /
  `too_early` / `unrecognized`), printed in that fixed order.

Output ordering is byte-stable across runs (NFR-003 spirit). `--stats` and
`--print` are mutually exclusive (usage error, exit 2).

## Trace format

`replay_trace.schema.json` (JSON Schema 2020-12) is the contract; CI
validates every checked-in trace against it. Harness-specific notes:

- **Family mapping** — `family` is a string in JSON; the harness maps it to
  the kernel's numeric constants: `COMPOSITE_SQUEEZE_ZONE` = 1
  (`CUE_EVENT_FAMILY_COMPOSITE_SQUEEZE_ZONE`). Unknown families are a hard
  error, not a skip.
- **Ordering** — sample `t_ms` must be strictly increasing (stricter than the
  kernel's non-decreasing contract) so every observation and recorded
  decision maps to exactly one sample. Observations or recorded decisions
  whose `t_ms` matches no sample are a trace error (exit 2), not divergence:
  the kernel never saw the observation live and cannot be replayed to a
  timestamp it was never stepped to.
- **Recorded decisions** — producers must log every `HEAD_UP`; logging
  suppressed (`NONE`) decisions is optional. A kernel `HEAD_UP` with no
  matching record is therefore counted as divergence, while an unrecorded
  `NONE` sample is fine.

## Checked-in traces

All traces are synthetic — hand-authored ride on segments 7/8 at a constant
5 m/s with two squeeze-zone events; no real GPS coordinates (NFR-005).

| Trace | Purpose |
| --- | --- |
| `traces/squeeze_loop_baseline.json` | Spec §8 default config. Event 101 cues at 15 s lead (`HEAD_UP`) after a too-early suppression; later observations exercise `ALREADY_CUED`, `TOO_LATE`, `INSIDE_EVENT`, and event 102 shows `COOLDOWN_TIME` before cueing. Rider grades the cue `too_late`. |
| `traces/squeeze_loop_tuned.json` | Before/after policy comparison (spec §13 milestone 2): same ride, `max_notice_s` widened 15 → 20 after the baseline `too_late` review (§12 tuning direction). The same event 101 now cues at 18 s lead — three seconds earlier — and the rider grades it `useful`. |
| `tests/config_drift_divergence.json` | Must FAIL replay. Baseline decisions recorded under `severity_threshold` 128, but the trace claims 210 — the kernel suppresses event 101 and cues 102 early, so the harness must exit nonzero. Proves divergence detection works. |
