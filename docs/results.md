# Field Results

Every figure on this page is aggregated from the operator's local ride
corpus by
[`tools/cue-results/aggregate.py`](../tools/cue-results/aggregate.py) — run
`python3 tools/cue-results/aggregate.py` from the repo root to reproduce it.
The corpus itself (`rides/`) is field data and stays out of the repo
(NFR-005 — it is gitignored), so this page is a dated snapshot, and the
command reproduces it wherever the corpus lives, not on a fresh clone. For
a corpus a fresh clone *can* reproduce, `make demo-corpus` generates a
synthetic, coordinate-free ride set that the same tools consume
(`aggregate.py demo-rides`, `ablate.py demo-rides`).
Negative results stay on the record: missed coverage is preferable to noisy
cueing (NFR-001), and the same ethos applies to reporting.

Corpus snapshot: rides of 2026-07-20 through 2026-08-08.

Re-verified 2026-09-12: [23/23 traces and regenerated aggregate evidence](field-reverification.md).
Raw GPS exports remain private.

## The equivalence contract

The same `kernel/cue_policy.c` runs in three places — live on the phone, as
the MCU actuator (Pico W, RFC 0006), and offline in the replay harness — and
the contract is that all three agree on the recorded logical decision fields.
Shared code can also share defects.

| Contract check | Result |
| --- | --- |
| Offline replay of every corpus ride trace (`replay_cli`, NFR-003) | **23/23 traces exit 0** — every recorded decision reproduced exactly |
| Phone ↔ Pico shadow comparison, per-step, live during rides (RFC 0006 D5) | **11,301 steps logged, 11,300 compared, 0 divergences, 0 orphan reports** across 8 instrumented rides |
| Pico state-size tripwire (SESSION_ACK `state_size` vs. `static_assert`) | Implemented session-start guard; same-size behavioral drift can pass it |

The one logged-but-uncompared step is a tail record with no recorded report.
Its tail position is confirmed; the cause of the
missing report is not independently established by this re-verification.

## Corpus

| Metric | Value |
| --- | --- |
| Ride traces | 23 (19 with motion; the rest are stationary bring-up captures, kept because they replay too) |
| Distance | 88.1 km |
| Kernel steps | 57,783 |
| `HEAD_UP` cues fired | 42 |
| Cues graded by the rider | 33, across 13 rides |

## Cue quality (rider grades)

| Grade | Count | Reading |
| --- | --- | --- |
| `useful` | 17 | |
| `too_late` | 7 | Drove the §13 `max_notice_s` 15 → 20 widening — which then failed and is on the record in `kernel/cue_policy.h` |
| `unrecognized` | 7 | A delivery/perceptibility outcome, not a policy one (see [grading-guide.md](grading-guide.md)) — moves no policy lever |
| `too_early` | 2 | |
| `false_alarm` | 0 | |

## Delivery (the honest negatives live here)

The exports expose incomplete delivery coverage across watch haptics and
the Pico buzzer. Replay agreement cannot rule out policy defects or prove
that output reached the rider.

| Metric | Value |
| --- | --- |
| Watch dispatches | 49 |
| Marked delivered live by watch telemetry | 27 (median latency **542 ms**, min 25, max 2,890; n=27) |
| Queued without recorded live delivery | **22** of 49 dispatches; not a general failure-rate estimate |
| Of the 27 delivered: watch verdict `play` | 18 (4 `duplicate`, 5 pre-verdict schema) |
| Pico reported actuations | 15 records marked actuated |
| Reported buzzer actuation delay (decision → GPIO) | 138–173 µs (median 147 µs, n=13; 2 early records at ms resolution) |

The `unrecognized` grades and queued dispatches concern different observation
boundaries. Their aggregate counts do not establish a cue-by-cue causal link.
Transport acknowledgements, play verdicts and actuation flags do not independently
prove physical output or perception. The 49 dispatches are not 49 unique kernel cues.
