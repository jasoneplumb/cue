# Replay Ablations

What the policy's machinery actually does on real rides — answered by
re-running the recorded corpus through kernel variants, with zero new riding.
Reproduce with `python3 tools/cue-ablation/ablate.py` — paths resolve
against the repo root, so any CWD works (2026-08-12 corpus: 23 traces,
88.1 km, 57,783 steps, 42 recorded cues; the corpus itself is local field
data, gitignored per NFR-005).

This is the replay harness used as a research instrument rather than a
regression suite: the same `--print` evaluation that authors fixtures
re-scores the whole field corpus under a modified policy in seconds.

## Variants

| Variant | What changes | How |
| --- | --- | --- |
| `baseline` | Nothing — sanity anchor | Traces exactly as recorded; must reproduce all 42 recorded cues (and does) |
| `no_memory` | Personal route memory (RFC 0002) disabled | `personal_memory` stripped from each trace |
| `no_thresholds` | Severity/confidence thresholds and both cooldowns removed | `policy_config` rewritten to 0 (notice window, speed gate, and the FR-004 one-cue-per-event budget stay) |
| `every_zone` | `no_thresholds` **plus** the notice window blown open (0–32,767 s) | The true "cue once per approached zone" upper bound: only the speed gate, inside-event check, and FR-004 budget remain |
| `distance_gate` | Distance window instead of time-to-event | `replay_cli` rebuilt with `-DCUE_ABLATION_DISTANCE_GATE` (kernel `#ifdef`, replay ablation builds only — `#error`-guarded out of `PICO_BUILD` firmware): cue when 30 m ≤ distance ≤ 115 m — the 5–20 s window at the corpus median cue-moment speed of 5.8 m/s |

## Results

| Variant | Cues | Lead s min/med/max | In 5–20 s window | Suppressions (full histogram) |
| --- | --- | --- | --- | --- |
| `baseline` | 42 | 12 / 15 / 20 | 42/42 | TOO_SLOW 21,196 · TOO_EARLY 6,733 · INSIDE_EVENT 1,909 · ALREADY_CUED 564 · TOO_LATE 347 |
| `no_memory` | 42 | 12 / 15 / 20 | 42/42 | TOO_SLOW 21,196 · TOO_EARLY 6,733 · INSIDE_EVENT 1,909 · ALREADY_CUED 580 · TOO_LATE 331 |
| `no_thresholds` | 42 | 12 / 15 / 20 | 42/42 | identical to baseline |
| `every_zone` | **83** | 34 / 226 / 1,748 | **0/83** | TOO_SLOW 21,196 · ALREADY_CUED 7,589 · INSIDE_EVENT 1,899 · TOO_LATE 24 |
| `distance_gate` | 41 | 6 / 19 / 73 | **24/41** | TOO_SLOW 21,196 · TOO_EARLY 6,488 · INSIDE_EVENT 1,906 · ALREADY_CUED 763 · TOO_LATE 397 |

## Findings

**1a. The kernel's threshold and cooldown gates have never bound in the
field.** `no_thresholds` is decision-identical to baseline: across 57,783
field steps, not one suppression came from severity, confidence, or either
cooldown. The reason is upstream: every one of the corpus's 37,349
observations arrives with severity ≥ 128 and confidence ≥ 128 — the phone's
squeeze scoring is the first filter, and the corpus never presents the
kernel a sub-threshold zone. The kernel gates are the MCU-side defense in
depth for inputs the phone no longer prefilters — a role this corpus cannot
exercise. (Scope: this claim is about the threshold and cooldown gates
only; the notice window is measured separately below.)

**1b. The notice window is the load-bearing noise gate.** `every_zone` —
thresholds *and* window removed — nearly doubles the cue count (42 → 83)
and puts **zero** of them in the 5–20 s spec window: cueing a zone at first
sight fires a median 226 s (up to 29 minutes) before the squeeze, and
because each cue spends the event's FR-004 budget slot at that first
sighting (ALREADY_CUED 564 → 7,589), the useful in-window moment can never
cue again. On this corpus, essentially all of NFR-001's noise control that
the kernel itself provides lives in the notice window plus the speed gate
(TOO_SLOW 21,196).

**2. Personal route memory has not yet changed a single field decision.**
`no_memory` produces the same 42 cues. The corpus carries 239 memory
records — 83 UNSAFE, 29 with a +2 s notice bonus — but UNSAFE only bypasses
a severity gate that never binds (finding 1), and a 5 → 7 s minimum-notice
widening cannot bind when the corpus's shortest lead is 12 s. The histogram
shows the mechanism working exactly as specified and mattering exactly zero:
16 steps shift between TOO_LATE and ALREADY_CUED, and no cue moves. The
lever is armed but has not yet been reached by field conditions.

**3. Speed normalization is what the time window buys — a distance window
demonstrably fails this corpus.** Cue-moment speeds span 0.9–17.1 m/s
(3.3–61 km/h). A 30–115 m window — calibrated to be *exactly equivalent* to
5–20 s at the median cue speed — keeps only **24 of 41** cues inside the
notice window the spec asks for, fires one cue at a 73 s lead (a slow
approach at long distance), and drops one recorded cue outright. Same
corpus, same calibration point, 41% of cues out of spec: time-to-event is
not a stylistic choice, it is what makes one window serve the whole field
speed range.

## Caveats

- Negative results 1a and 2 are statements about *this corpus*, not the
  mechanisms: they quantify how far field conditions have exercised each
  lever, and they will move as the corpus grows (a region without upstream
  scoring, a memory-suppressed repeat route).
- The `distance_gate` kernel variant lives behind
  `-DCUE_ABLATION_DISTANCE_GATE` and is compiled only by the ablation tool
  (via `replay/Makefile`'s own recipe, so the binary cannot drift from the
  one CI tests); a `#error` rejects the flag in `PICO_BUILD` firmware, and
  the default build is byte-identical with the flag unset.
- `--print` evaluates without verifying, so ablated variants (which diverge
  from recorded decisions by design) run to completion; the `baseline`
  variant doubles as the harness's own sanity check by reproducing all 42
  recorded cues.
