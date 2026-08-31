# RFC 0002: Personal Route Memory

- **Status:** Implemented (PRs #119 kernel, #120 replay, #121 phone,
  #125 cue-custom-zone-merge)
- **Date:** 2026-07-08
- **Closes:** #11

**Amended by [RFC 0008](0008-directional-custom-zones.md)** (directional
custom zones): D1's record gains `unsafe_dir_mask`, and D2's "markers
dominate" rule now distinguishes the two marker sources it deliberately
collapsed here. An in-ride tap still dominates omnidirectionally; an
imported custom zone carries a direction, no longer contributes to
`marker_count`, and applies only when the rider is travelling its way. The
D7 budget is unchanged (17 B -> 18 B packed, still rounding to 20 B).

**Implementation deviations from this design:**

- D5's `SUPPRESS` gate is implemented as raising the effective severity
  threshold to the **literal** `UINT8_MAX`, not merely "toward" it as the
  prose above phrases it — a genuinely severe new event (severity ==
  `UINT8_MAX`) can still cue; nothing softer than that was implemented.
- D5's multi-segment tiebreak ("nearest segment ahead") is honored by the
  live phone resolver (`RideEngine.resolveMemory`), but the offline
  `cue-custom-zone-merge` desk tool (follow-up work beyond this RFC's
  original follow-up list, closing the webmap.dev custom-zones loop) uses
  a simpler smallest-segment-id tiebreak instead — it has no live approach
  context to rank by. Documented as a known, bounded divergence in
  `CustomZoneImport.personalMemoryChangePoints`.
- D6's "producers MUST end every trace's `personal_memory[]` with a clear
  record" is intentionally NOT followed when the ride itself ends with
  memory still active: both `RideTraceRecorder` (live) and
  `CustomZoneImport.personalMemoryChangePoints` (offline) leave the trace
  carry-forward-active in that case, because a synthetic terminal clear
  would make the ride's own last sample replay under `NEUTRAL` despite
  being decided under the active state — reintroducing exactly the
  divergence D6 exists to prevent. `replay_main.c`'s end-of-trace
  "carry-forward-active" warning is the deliberate, non-failing signal for
  this, not a gap.

## Context

The design spec §9 calls for **personal route memory**: the system should learn
from a rider's own history on a given map segment and let that history bias the
cue policy. Two history sources exist today (spec §5.11, both already in the
replay schema):

1. **Cue outcome history** — after-ride reviews grade each fired cue
   `useful`, `false_alarm`, `too_late`, or `unrecognized` (FR-008; schema
   `reviews[]`). `unrecognized` (a cue that fired but the rider never
   noticed) is a delivery/attention signal, not a policy-correctness
   signal, and is out of scope for the derivation below (D2/D4) — it does
   not get a store counter.
2. **Explicit unsafe-marker history** — the rider taps `unsafe_here` during a
   ride (FR-006; schema `markers[]`). This is also the mechanism for "the
   policy should have cued here and didn't" — there is no separate
   after-ride review outcome for that case (see RFC 0003 D7).

Both are keyed to a `segment_id` (the matched map segment; `RideSample.segment_id`
/ `RouteEvent.segment_id` in `kernel/cue_policy.h`). The kernel already reserves
`reasons_bitmask` bits 12–15 for "personal history" (spec §7, header comment) and
notes the hook point — *before the severity gate* — in the `Future` header of
`kernel/cue_policy.c`.

This RFC decides **how personal route memory is stored, derived, bounded, and fed
to the kernel** without violating the deterministic (NFR-003), allocation-free /
fixed-size (NFR-004), conservative-cueing (NFR-001), or privacy (NFR-005)
constraints. It changes no code, the replay harness, or the schema; those land as
the follow-up issues listed at the end.

Scope boundary (repo module boundaries): the **store and its derivation live
phone-side**; only a small fixed-size *resolved* input crosses into the kernel, so
the kernel stays pure C with no map, no history database, and no allocation. This
mirrors the existing split — map matching and route-event generation are already
phone-side; only normalized inputs migrate to the MCU.

## Decisions

### D1 — Store contents (spec §5.11)

The personal-route-memory store is a **phone-side, per-segment record** keyed by
`segment_id`. Each record aggregates the two history sources into fixed-size
counters plus one marker field:

| Field                 | Type              | Meaning                                                  |
| --------------------- | ----------------- | -------------------------------------------------------- |
| `segment_id`          | `uint32`          | Map segment key (matches kernel `segment_id`).           |
| `useful`              | `uint16` (satur.) | Count of `useful` reviews on this segment.               |
| `false_alarm`         | `uint16` (satur.) | Count of `false_alarm` reviews.                          |
| `too_late`            | `uint16` (satur.) | Count of `too_late` reviews.                             |
| `marker_count`        | `uint16` (satur.) | Count of explicit `unsafe_here` markers on this segment. |
| `notice_bonus_s`      | `uint8`           | Accumulated per-segment notice bonus, +2 s per `too_late` review (see D4). Same name as the kernel-input field (D5), which the phone copies verbatim — one greppable bridge, no mapping table. |
| `lru_touch`           | `uint32`          | Monotonic **global write counter** (not wall-clock — RTC-free, so the eviction strategy stays portable to the Phase 4 sensor pod) for least-recently-touched eviction (D7). Bookkeeping only — never an input to derivation (D2). 2³² writes before wrap is unreachable in practice. |

Counters **saturate** at their max rather than wrapping (consistent with the
kernel's saturate-don't-wrap discipline for cooldowns). Storing counts — not raw
event logs — keeps the store bounded (D7) and stores only what cue tuning needs
(NFR-005). Outcomes are attributed to a segment by joining each review's
`event_id` to the `RouteEvent.segment_id` observed for that event in the same
ride; markers carry `segment_id` directly.

### D2 — Derivation rule: explicit markers dominate (spec §5.11)

A record resolves to at most **one** of three memory states for the kernel, in
strict precedence order — **explicit markers dominate**:

1. **`unsafe` (marker-dominant).** If `marker_count > 0`, the segment is treated
   as rider-flagged unsafe **regardless of outcome history**. An explicit
   "unsafe here" is a deliberate, high-signal rider act; it overrides any
   `false_alarm` count. This is the conflict-resolution rule: markers win, full
   stop.
2. **`suppress` (history-dominant).** Else, if `false_alarm >= FALSE_ALARM_MIN`
   **and** `false_alarm` strictly exceeds `useful`, the segment is
   treated as over-cued and cueing is biased **down** (see D5). This requires a
   marker count of zero by construction (rule 1 already returned).
3. **`neutral`.** Otherwise the segment contributes no bias; the kernel behaves
   exactly as today.

`too_late` outcomes do **not** feed the suppress/unsafe state — they feed the
*tuning* rule (D4) instead, because "cue was right but late" is a timing fix, not
a keep/kill signal. `unrecognized` outcomes likewise do not feed this state (see
Context, above). `FALSE_ALARM_MIN` defaults to **2** (one stray `false_alarm`
never suppresses; conservative per NFR-001 — we would rather keep cueing than
silence a segment on thin evidence).

**Rationale for "markers dominate":** the two sources have different
epistemics. A review is a retrospective judgement of one cue; a marker is a
prospective, in-the-moment "this place is dangerous." Letting a marker override
`false_alarm` cannot *suppress* a cue (unsafe only ever biases toward cueing), so
the failure mode of trusting markers is at most a redundant `HEAD_UP` — the
conservative direction (NFR-001).

### D3 — Marker effect window: matched segment + approach window (spec §5.12)

Memory for a segment applies to the **matched segment itself plus an approach
window** ahead of it, so an `unsafe`/`suppress` bias is in effect while the rider
is *approaching* the segment, not only once on it. The window is a distance
computed from current speed and a desired lead time:

```
approach_window_m = clamp(current_speed_mps × desired_lead_time_s,
                          min_approach_m, max_approach_m)
```

Defaults (spec §5.12): `desired_lead_time_s = 10`, `min_approach_m = 25`,
`max_approach_m = 100`.

**Where it lives: phone-side.** The window governs *which segment's memory record
applies to the current position* — that is map-matching / spatial-join work, and
map matching is already phone-side per the module boundaries. The phone resolves
the applicable record before it calls the kernel, so the kernel never sees speed
× time geometry or a segment graph. This keeps `approach_window_m` out of the
kernel entirely (NFR-004: no new float math, no distance search on the MCU).

Note the arithmetic is intentionally the *dual* of the kernel's existing
`min_notice_s` time gate: the notice gate asks "is the event within N seconds of
*time*?"; the approach window asks "is a remembered segment within N seconds of
*distance* ahead?" They share the lead-time intuition but operate on different
axes, so they do not collapse into one another.

### D4 — Tuning rule: +2 s after `too_late`, per segment/event-family first (spec §5.12)

`too_late` reviews tighten the *timing*, not the keep/kill decision. Rule:
**after each `too_late` review, add +2 s to that segment's notice bonus**, applied
**per segment / event-family first** (the narrowest scope that has evidence),
before any global change.

Representation: the store's `notice_bonus_s` (D1) accumulates `+2` per
`too_late` review, saturating at a cap (`MAX_TOO_LATE_BONUS_S`, default **8 s** =
four corrections — beyond that the segment is systematically mis-timed and should
be escalated to a global `min_notice_s`/`max_notice_s` change via the normal
tuning loop, not silently widened forever).

**Composition with `CuePolicyConfig`:** the bonus is a **per-segment additive
override on the notice window**, not a replacement config. The kernel keeps a
single global `CuePolicyConfig`; the per-segment bonus arrives as one resolved
field in the memory input (D5) and is applied as:

```
effective_min_notice_s = min_notice_s + notice_bonus_s
effective_max_notice_s = max(max_notice_s, effective_min_notice_s)
```

Widening the *minimum* notice makes the cue fire **earlier** (more lead time),
which is exactly the `too_late` correction. The `max(...)` re-clamp preserves the
kernel's existing invariant that `min_notice_s <= max_notice_s`
(`cue_policy_init`, PR #7 / #8) even when a large bonus would otherwise invert the
window. This composes cleanly: with `notice_bonus_s == 0` the kernel's behavior is
byte-for-byte unchanged.

**Integer width (mirror of D2's note):** `effective_min_notice_s` must be
computed in a 32-bit intermediate — `min_notice_s` (`uint16`, up to 65,535)
plus `notice_bonus_s` (`uint8`) can reach 65,790, and a `uint16` local would
wrap to a tiny value, firing the cue far too *early* — the opposite of the
`too_late` correction. Follow-up #2 computes the sum in `int32`/`uint32` and
clamps consistently with `cue_policy_init`'s existing `INT16_MAX` discipline.

**Window-collapse edge case (documented, accepted):** the `max(...)` re-clamp
can narrow the window to a single point when the bonus is large relative to
`max_notice_s − min_notice_s` — e.g. a custom `[5, 7]` window with a 4 s
bonus becomes `[9, 9]`, cueing only at exactly 9 s lead. Benign with the
spec §8 defaults (`[5, 15]` + 8 s cap ⇒ `[13, 15]`), but implementers of
follow-up #2 should not be surprised when narrow custom configs plus a large
bonus make cues sparse; the escalate-to-global rule above is the pressure
valve.

### D5 — Kernel surface: a new fixed-size input struct, not the reasons bits

Two candidate surfaces were considered for getting memory into the kernel:

| Option                                    | Verdict  | Why |
| ----------------------------------------- | -------- | --- |
| **A. Overload `reasons_bitmask` bits 12–15** | Rejected | The bitmask describes *why an event exists* (infrastructure/traffic evidence); personal history is *rider state*, not an event property. Four bits cannot carry the `notice_bonus_s` value (D4) and would conflate "the world is narrow here" with "this rider dislikes cues here." Reserve bits 12–15 for their spec-§7 purpose (event-level personal-history *evidence*, e.g. "rider has been cued here before"), distinct from the memory *decision*. |
| **B. New `PersonalMemory` input struct**  | **Chosen** | An explicit, fixed-size, resolved input keeps the kernel a pure step function and makes the phone/kernel contract legible. |

The kernel gains one new **fixed-size, allocation-free** struct, resolved
per-step by the phone for the currently-applicable segment:

```c
/* Resolved personal-route-memory input for the current step (spec §9).
 * Phone-resolved: the phone joins the rider's per-segment store to the
 * current position/approach window (RFC 0002 D2/D3) and passes the single
 * applicable record. All fields fixed-size; NULL means "no memory this step",
 * so a memory-free ride is byte-for-byte identical to today (NFR-003/004). */
typedef struct {
  uint32_t segment_id;   /* segment this record applies to; 0 reserved = none */
  uint8_t  state;        /* CUE_MEMORY_NEUTRAL / _UNSAFE / _SUPPRESS (D2) */
  uint8_t  notice_bonus_s; /* copied verbatim from the store record (D1/D4) */
} PersonalMemory;
```

`segment_id` is **load-bearing, not diagnostic**: the kernel applies the
`state` bias and `notice_bonus_s` only to events whose
`RouteEvent.segment_id` matches — without the match, an `unsafe` record for
the approaching segment would leak severity bypasses onto unrelated
same-step events. The value `0` is reserved as "no record"; the phone-side
store must never persist segment 0. Enforcement belongs **upstream, at ID
allocation**: the map importer must allocate real segment ids starting at 1
(a real segment assigned id 0 would have its memory silently discarded on
every write — for a marked-unsafe segment that is a safety-relevant silent
failure), and follow-up #3 adds `"minimum": 1` to the schema's `segment_id`
wherever `personal_memory[]` uses it; follow-up #5 asserts it in the store.
A record with
`state == NEUTRAL` and `notice_bonus_s == 0` is byte-for-byte equivalent to
passing `memory == NULL`.

**Multi-segment resolution (phone-side, deterministic):** a step's events can
span several segments, but the kernel receives exactly one record. When more
than one remembered segment falls inside the approach window in the same
step, the phone passes the **highest-precedence** record — `unsafe` >
`suppress` > `neutral`, ties broken by **nearest segment ahead** — so any two
correct implementations resolve identically (NFR-003). Events on other
segments get neutral treatment that step; their records apply when they
become the resolved segment.

`cue_policy_step` gains an optional trailing `const PersonalMemory *memory`
argument (or a paired `_ex` entry point if we choose to preserve the current
signature — decided at implementation time; both keep the memory-free path
unchanged). **Hook point: before the severity gate**, per the
`kernel/cue_policy.c` `Future` note, so memory can act before an event is even
evaluated:

- **`state == UNSAFE`** → the segment bypasses the **severity** threshold
  only (the rider has asserted risk that the model may under-*score*). The
  **confidence gate is retained**: confidence measures whether the event
  exists at all, and an unsafe marker must not convert map-matching noise
  (a zero-confidence phantom event) into taps — that would be the exact
  opposite of NFR-001. The event **still passes every downstream gate**
  (confidence, inside-event, speed, notice window, already-cued, cooldowns). Memory can only *promote an event that
  the model already produced*; it never fabricates a cue and never bypasses
  FR-004 (one HEAD_UP per event) or the cooldowns. This is the conservative
  bound: worst case is one extra *eligible* event, still rate-limited.
  Note the inside-event gate in particular: a rider already **inside** a
  marked-unsafe segment still gets **no** cue. That is intended, not an
  oversight — the product cues on *approach* ("one tap = head up now,"
  §5.7 — before the squeeze, never mid-zone), so `unsafe` is *not* an
  "always produce a cue here" flag.
- **`state == SUPPRESS`** → the segment's severity threshold is raised toward
  `UINT8_MAX` (effectively "only cue if the model is nearly certain"), biasing the
  segment down without hard-muting it (a genuinely severe new event still cues).
  A new reason code `CUE_REASON_CODE_MEMORY_SUPPRESSED` names the gate for replay
  debugging.
- **`notice_bonus_s`** → applied to the notice window per D4, for **any** state
  (a `too_late` bonus is orthogonal to unsafe/suppress).

Determinism (NFR-003): memory is a **pure function of its input** — the kernel
does not read a clock, does not mutate the store, and does not allocate. Given the
same `(sample, events, memory)` it returns the same decision. The store's *update*
(counting reviews/markers into records) happens phone-side, after the ride, and is
itself replayable from the trace (D6).

### D6 — Replay: schema extension and version bump

For a memory-influenced decision to replay deterministically (NFR-003), the trace
must carry the resolved memory the kernel saw. Extension to
`replay_trace.schema.json`:

- Add an optional **`personal_memory[]`** array of stamped records:
  `{ t_ms, segment_id, state, notice_bonus_s }`, mirroring `PersonalMemory`.
  Records are stamped to a sample `t_ms`, but **unlike `route_events[]`
  (exact-match, re-observed at every relevant sample), memory records use
  carry-forward semantics**: a record applies from its `t_ms` (inclusive)
  until the next record's `t_ms`, and producers log one only when the
  resolved input *changes* — memory changes far too rarely to stamp every
  sample, and an exact-match rule would silently replay all other samples
  memory-free. Returning to memory-free is itself a change: producers log an
  explicit clear record (`state: NEUTRAL`, `notice_bonus_s: 0`), which the
  kernel treats byte-for-byte as `memory == NULL` (D5). Absent/empty array ⇒
  memory-free replay, identical to today.
  **Producer contract (carry-forward failure mode):** carry-forward means a
  dropped clear record (mid-ride crash, lost write) silently replays the
  remaining samples with stale memory — a quiet NFR-003 hazard exact-match
  stamping doesn't have. Two mitigations, both in follow-up #3: producers
  MUST end every trace's `personal_memory[]` with a clear record (ride-end
  flush), and the harness warns when a trace ends carry-forward-active, so a
  truncated ride is visible rather than silently stale.
  **Implementation deviation:** the ride-end flush described above is
  intentionally omitted by both shipped producers — see the
  *Implementation deviations* block at the top of this RFC for the
  rationale (a synthetic flush would make a still-active ride's own last
  sample replay under `NEUTRAL`). The `replay_main.c` end-of-trace
  "carry-forward-active" warning is the substitute signal.
- The store *itself* is **not** serialized into the trace; only the **resolved
  per-step input** is. This keeps traces privacy-minimal (NFR-005 — no rider
  history database in every trace) and keeps replay a pure kernel-input replay,
  consistent with how `policy_config` (not the tuning process) is what the trace
  records.
- **`schema_version` bump 1 → 2.** Adding a new *optional* array is technically
  backward-tolerant, but the schema's own contract is "bump on any breaking
  change; replay tools refuse unknown versions," and a v1 replay tool would
  silently *ignore* `personal_memory` and so mis-replay a memory-influenced ride
  as memory-free — a silent divergence, which is exactly what the harness exists
  to catch. Bumping to 2 makes old tools refuse the trace loudly instead. Policy
  going forward: **bump when the kernel can read a field a prior tool cannot**,
  even if JSON-Schema validation would still pass.

### D7 — Privacy & memory budget (NFR-005, NFR-004)

**Local-only.** The store never leaves the device except inside an explicitly
exported trace, and even then only as the resolved per-step input (D6), never as a
standing history database. This satisfies NFR-005 ("store only data necessary for
cue tuning and replay") — counts and a bonus, not timestamps or coordinates.

**Fixed-size budget — phone-side store, sized MCU-ready.** To be unambiguous
about layers (the kernel never holds this store): the canonical store lives
**phone-side** (D5); the kernel receives exactly one resolved
`PersonalMemory` record per step (6 field bytes; 8 with alignment padding),
nothing more. The fixed-size discipline
below exists so the store can migrate onto an MCU-resident static table in
the Phase 4 sensor-pod scenario (no phone in the loop) without redesign.
Following the sizing style of the `CUE_POLICY_CUED_EVENTS_CAP` comment in
`cue_policy.h`:

```
Per-segment record (D1), packed:
  segment_id       4 B (uint32)
  useful           2 B (uint16)
  false_alarm      2 B (uint16)
  too_late         2 B (uint16)
  marker_count     2 B (uint16)
  notice_bonus_s   1 B (uint8)
  lru_touch        4 B (uint32)  eviction bookkeeping (below)
  ------------------------------
  = 17 B/record → round to 20 B/record (alignment/pad)

Cap: CUE_POLICY_MEMORY_SEGMENTS_CAP = 256 remembered segments
  256 × 20 B = 5120 B = 5 KiB total, fixed, no allocation.
```

256 segments at a worst-case ~75 m squeeze-zone spacing covers ~19 km of
*remembered* (previously-flagged or reviewed) route — a rider's regular commute
and then some — while fitting a 5 KiB static array comfortably within an MCU's
RAM if/when the store migrates. When full, evict by **least-recently-touched**
segment (the LRU stamp travels with the store, wherever it runs). If a full
store drops a segment, that segment simply reverts to `neutral` — conservative
(NFR-001), never a spurious cue. **This cap is a bound, not a silent
truncation: the store owner logs an eviction so tuning sees when the store is
under pressure.**

## Consequences

- **Kernel** gains one optional fixed-size input and one hook before the severity
  gate; the memory-free path is byte-for-byte identical to today (NFR-003/004
  preserved; `notice_bonus_s == 0` and `memory == NULL` ⇒ no behavior change).
- **Conservative-cueing (NFR-001) is preserved by construction:** memory can
  *promote* eligibility (`unsafe`) or *demote* it (`suppress`) but never bypasses
  the inside-event, notice, already-cued (FR-004), or cooldown gates. The most it
  can do is add one extra *eligible* event, still rate-limited to one HEAD_UP per
  event and subject to cooldown.
- **Determinism (NFR-003) is preserved:** the kernel reads memory as pure input;
  all store mutation is phone-side and replayable from the trace.
- **`reasons_bitmask` bits 12–15 stay reserved** for their spec-§7 meaning
  (event-level personal-history *evidence*), decoupled from the memory *decision*
  carried by `PersonalMemory` — no overloading, no future collision.
- **Schema breaks to v2**; replay tools must refuse v1↔v2 mismatches, and every
  checked-in trace stays v1 until the memory feature lands (they contain no
  `personal_memory`).
- **Cost:** a new phone-side store + resolver (5 KiB fixed budget, sized to
  migrate MCU-side in Phase 4), one new reason code, and a schema/replay
  update — spread across the follow-up issues below so no single PR touches
  kernel + schema + replay at once.
- **Non-goals reaffirmed:** memory tunes *cue timing and selectivity* only; it
  makes **no** safety, crash-prevention, medical, or fitness claim (spec §3), and
  stores no data beyond per-segment counts and a bonus (NFR-005).

## Follow-up implementation issues to file

*(Titles + one-line scope; not created by this RFC.)*

**Sequencing constraint:** follow-up **#3 must land before any production
path can emit `schema_version: 2`** (i.e., before #5/#6/#7 ship into the
app). Otherwise a truncated `personal_memory[]` from a mid-ride crash could
replay silently with stale memory — the exact NFR-003 hazard the carry-forward
producer contract (D6) and the version bump exist to prevent. #1/#2 (kernel)
and #4 (traces) may proceed in parallel; only trace *production* is gated.

1. **`kernel: PersonalMemory input struct + pre-severity hook`** — add the
   fixed-size struct (D5), the memory-free-equivalent step path, and
   `CUE_REASON_CODE_MEMORY_SUPPRESSED`; unit tests proving `memory == NULL` is
   byte-for-byte unchanged.
2. **`kernel: per-segment notice_bonus_s application + window re-clamp`** —
   apply D4's additive bonus with the `max(...)` invariant guard; tests for the
   `too_late` → earlier-cue path and the saturating cap.
3. **`replay: schema v2 — personal_memory[] + version-refusal`** — extend
   `replay_trace.schema.json` (D6) with carry-forward stamping semantics, bump
   `schema_version` to 2, and make the harness refuse v1/v2 mismatch loudly.
4. **`replay: memory-influenced example traces`** — add synthetic
   `unsafe`/`suppress`/`too_late-bonus` traces demonstrating deterministic
   memory replay and a config-drift-style fixture that must fail.
5. **`phone: per-segment memory store + counters (D1)`** — implement the
   saturating per-segment record, review/marker attribution join, and LRU
   eviction with the 5 KiB (D7) budget.
6. **`phone: derivation resolver — markers-dominate precedence (D2)`** — resolve
   a record to `neutral`/`unsafe`/`suppress` with `FALSE_ALARM_MIN`; unit tests
   for the marker-vs-false_alarm conflict.
7. **`phone: approach-window resolver (D3)`** — compute `approach_window_m` and
   the spatial join that selects the applicable segment record per step.
8. **`docs: personal-memory tuning runbook`** — document how `notice_bonus_s`
   accumulation escalates to a global `CuePolicyConfig` change (D4 cap) in the
   spec §13 tuning loop.
</content>
</invoke>
