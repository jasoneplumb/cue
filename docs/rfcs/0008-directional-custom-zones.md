# RFC 0008: Directional Custom Zones

- **Status:** Implemented (PRs #31 map-import, #32 memory + live gate, #33 desk tool)
- **Date:** 2026-08-30
- **Tracking:** #30
- **Amends:** RFC 0002 D1 (record fields), D2 (derivation)

> **Reading the decision references.** A bare `D<n>` here means *this* RFC's
> own decision. Every reference to another record is qualified — `RFC 0002
> D5`, `RFC 0003 D2`.

## Context

A custom squeeze zone is drawn by hand in webmap.dev and imported into the
app, where it lands in personal route memory as rider-asserted risk on the
segments it snaps to (RFC 0002 D2 — a drawn zone and an in-ride "unsafe
here" tap were deliberately collapsed into one epistemic category).

A drawn zone is a **LineString**, so it has always carried a direction —
first vertex to last. Nothing downstream kept it. `matchSegments` returned
bare segment ids, and `RideSessionController` baked each one into the store
as a directionless `marker_count` bump. After import the zone no longer
existed as an object; only the bump remained.

So a zone drawn for the descent of a road also biased cueing on the climb.
That is the case where a hand-drawn zone is most useful — a one-way squeeze,
a pinch that only bites downhill, a merge that exists in one direction — and
the case where two zones on the same road necessarily overlap. The rider had
no way to say "this only matters going this way."

This RFC decides how a zone's direction is authored, carried, stored, and
gated, without touching the kernel or the replay schema.

## Decisions

### D1 — The file carries a flag; the geometry carries the direction

The custom-zone GeoJSON contract (webmap.dev#277) gains **one optional
boolean**, `directional`. Absent or `false` means bidirectional — the
original contract, so every file exported before the property existed keeps
its exact meaning and is not a special case anywhere in either parser.

No bearing or heading property. The vertex order already *is* the direction;
a second field could disagree with the geometry it duplicates. Reversing a
zone is reversing its coordinates, which is why webmap.dev grew a Reverse
button — the one geometry edit that overlay allows, since a directional zone
drawn the wrong way round is otherwise unfixable without redrawing it.

`false` normalizes to absent on parse and is omitted on encode, so
localStorage and an exported file cannot hold two spellings of the same
thing for a zone nothing has changed.

### D2 — Direction is expressed against the segment, never stored as a bearing

Each `(zone, segment)` match resolves to a direction along **that segment's
own node order**: `FORWARD` (with it), `BACKWARD` (against), or both.

| Alternative | Verdict | Why |
| ----------- | ------- | --- |
| Store the zone's bearing per segment | Rejected | Ride-time comparison becomes a fuzzy bearing match with a second threshold to tune, and it costs bytes the memory record does not have. |
| **Two bits per (zone, segment)** | **Chosen** | Exact comparison, no quantization, and it fits on a personal-memory record without disturbing RFC 0002 D7's fixed-size budget. |

At import the comparand is the zone's **local** edge bearing at each snapped
vertex, not its overall start-to-end bearing — a drawn zone can curve across
several segments, and one bearing for the whole zone would misjudge every
segment but the straightest. A zone that doubles back inside one segment
unions to both, which is what the rider drew.

At ride time the comparand is the segment's **node-order chord**
(`RoadSegment.nodeOrderBearingDeg`). Segments are capped near
`SegmentImporter.maxSegmentLengthM`, so the chord tracks the road closely,
and it is the only bearing a consumer without live geometry can compute —
which is what buys D6 exact parity instead of an approximation. A segment
that bends more than the D3 gate could be judged the wrong way at its far
end: bounded, and rare at this segment length.

Every degenerate case resolves to **both**, never to a guess: a
non-directional zone, a lone vertex, a zero-length edge at either end of the
comparison, and a vertex whose outgoing neighbour is unusable. That last one
is not merely conservative — falling back to the *incoming* edge there would
return the exact opposite bearing on a zone that reverses after the gap, so
the zone would fire the wrong way, which is worse than not gating at all.

### D3 — The gate is ±90°: with the road, or against it

"Somewhat aligned" is **the same side of perpendicular**
(`TravelDirection.alignmentGateDeg`). Rationale:

- It is exactly the coming-and-going discrimination directional zones exist
  to make, and nothing narrower is needed to get it.
- It reuses the directed convention already shipped and calibrated as
  `RouteEventTracker.approachGateDeg`, rather than inventing a third
  threshold alongside `SegmentMatcher.headingGateDeg`'s mod-180 gate, which
  has different semantics.
- Anything tighter starts dropping legitimate cues on curving roads and on
  approach, where course and segment bearing legitimately diverge. Too wide
  a gate degrades to the pre-RFC behavior of firing both ways; too narrow a
  one silences a zone the rider asked for.

One constant, so §13 tuning has a single knob. An unknown course — standstill,
or CoreLocation reporting none — cannot reject anything, matching
`SegmentMatcher`'s heading gate.

### D4 — Direction latches per approach, but only once corroborated

Resolving fresh every sample lets course jitter near the gate dither the
bias and fill `personal_memory[]` with change points describing GPS noise.
So a segment's direction is **latched** while it is in play, mirroring
`RouteEventTracker.entryEndpoint`.

Latching on the *first* fix, however, is a worse failure than the one it
fixes. A transient course 91° off the segment latches the wrong way, every
correct fix afterwards is ignored, and the zone is gated out for the whole
approach — a **suppressed cue**, strictly worse than the pre-RFC behavior of
applying the record both ways. So the latch requires
`directionLatchSamples` (2) consecutive agreeing samples, the same
discipline `SegmentMatcher.hysteresisSamples` applies so "a single heading
spike cannot flap the match."

Direction resolves **once per distinct segment per step**, not once per
event. Two zones can snap to one segment, so a step can carry two events
naming it, and resolving per event advanced the corroboration counter twice
on a single fix — latching in one step and defeating the guard entirely.

Before it latches, each sample's own resolution is used **provisionally**
rather than withheld: a rider going the wrong way is gated out from the
first sample, as intended, and a spike costs exactly one sample. Two nil
meanings are kept apart — no course at all applies the record (the gate
cannot reject what it cannot measure); a measured-but-uncorroborated course
still gates.

The latch's scope is narrower than it first appears, and worth stating: it
holds the direction for a segment that stays **in play**. A course transient
large enough to trip `RouteEventTracker`'s own directed approach gate drops
the route event entirely, leaving no memory to resolve — pre-existing
behavior, unchanged by this RFC.

### D5 — Zone evidence and tap evidence are separate fields

RFC 0002 D2 collapsed drawn zones and in-ride taps into one category. A
direction breaks that collapse, because the two assert different things: a
tap is about the **place** and applies whichever way the rider is going; a
zone is about a **direction through** the place.

The record therefore gains `unsafe_dir_mask` describing **zone evidence
only**, and an imported zone no longer contributes to `marker_count`.
Derivation checks them in that order: `marker_count > 0` resolves unsafe
outright; otherwise a non-empty mask resolves unsafe when the direction
matches.

One shared mask was tried first and is wrong. With taps widening the same
field a zone had narrowed, `undoUnsafeMarker` could not narrow it back —
nothing attributes the widening to the tap that caused it. Import a
directional zone, tap that segment mid-ride, discard the ride, and the zone
fires both ways until the file is re-imported, breaking RFC 0002's #135
guarantee that a discarded ride leaves the store as it found it. Separate
fields make undo unable to disturb a zone, and re-import idempotent.

Consequences of the split:

- **Import REPLACES the whole imported-zone set.** webmap.dev's contract is
  that importing a file replaces what came before, and the cue side has to
  mean the same thing: a segment the rider deleted a zone from must stop
  being flagged, and writing only the segments the new file covers would
  leave it flagged forever with no way to take it back. Within the file,
  directions are unioned per segment across every zone that matched it, so
  processing order cannot decide the outcome. Segments whose only evidence
  was the departed zone are pruned; segments with taps or reviews keep those
  and lose only the zone. This is the second thing the separate zone field
  buys — a shared `marker_count` could not be cleared without discarding
  whatever the rider did during a ride.
- **A zone that does not apply this direction falls through to the suppress
  rule**, rather than short-circuiting to neutral. With the zone silent,
  review history is the only evidence left and should govern — a rider who
  flags a road unsafe eastbound and grades westbound cues as false alarms
  gets both judgments honored, each in its own direction.
- **The mask counts as evidence for pruning.** A zone-only segment has
  `marker_count == 0`, and dropping it on an unrelated undo would silently
  discard the import.
- **Budget unchanged.** 17 B → 18 B packed, still rounding to RFC 0002 D7's
  20 B/record, so 256 × 20 B = 5 KiB stands and the MCU-migration sizing
  story is untouched.
- **Legacy records decode with an empty mask** — "no zone asserts this" —
  and their `marker_count` still resolves omnidirectionally, exactly as
  before. This is load-bearing: `PersonalMemoryStore.load` answers a decode
  failure with an **empty store**, so a required new key would have silently
  discarded a rider's entire history on first launch after the upgrade. The
  hand-written `init(from:)` exists for that one reason.

### D6 — Desk-tool parity, and what to do when a trace cannot be gated

`cue-custom-zone-merge` resolves direction with the **same** node-order
bearing, the same ±90° gate, and the same corroborated latch as the live
engine — stated in both implementations, each pointing at the other. A desk
what-if that disagrees with the phone is not a tuning tool.

D2's choice of the segment chord over the matched edge is what makes this
exact rather than approximate: the tool needs only `segment_id` and
`heading_deg_x10`, never a GPS fix.

`heading_deg_x10` is optional (NFR-005) — a policy-tuning trace carries no
course at all. Those samples apply directional zones **both ways**: the
pre-RFC answer, chosen so an existing trace's result does not silently
change.

Two different things can leave a zone ungatable, and they are counted and
reported **separately** because the remedy differs: a missing course is
fixed by re-recording with the debug-GPS toggle, while a segment whose nodes
coincide has no bearing to compare against and no amount of re-recording
supplies one. One diagnostic for both would give advice that cannot work.
`--strict` refuses on either (the escape hatch `cue-events-export` already
offers for skipped events) and fails *before* writing, so a refused merge
leaves the trace untouched. A bidirectional zone is never counted — there is
nothing to gate.

### D7 — No kernel change, no schema bump

RFC 0002 D5 already puts the spatial join phone-side: "the phone resolves
the applicable record before it calls the kernel." A heading gate is
spatial-join work, so it lands entirely phone-side.

- **`kernel/` is untouched.** `PersonalMemory` (`segment_id`, `state`,
  `notice_bonus_s`) crosses the boundary already resolved.
- **`replay_trace.schema.json` is untouched — no v3.** `personal_memory[]`
  records the *resolved* input; gating changes only *when* a carry-forward
  change point is emitted. NFR-003 holds because the gate runs strictly
  upstream of what the trace records, so a recorded ride replays bit-exactly
  through an unmodified kernel.

One adjacent change fell out of this: a `NEUTRAL + 0` resolution is now
normalized to nil in `RideEngine`, **before** the kernel call, the Pico
link, and the trace recorder alike. It is byte-for-byte equivalent to
`memory == NULL` (RFC 0002 D5), so logging it as a change point tells replay
nothing — and a direction-gated segment resolves `NEUTRAL` on every pass the
other way, which would otherwise put a void record in the trace for each one.

Normalizing at the recorder alone was not enough, and the difference matters
for NFR-003: the live path was handing the kernel a NEUTRAL record while the
trace omitted it, so live and replay passed the kernel *different inputs for
the same rider state*. No divergence today, because the kernel ignores a
NEUTRAL record — but exactly the shape NFR-003 exists to prevent, the moment
it stops ignoring it.

## Deviations from the plan in #30

Recorded because the design changed materially under review, and the issue
is the wrong place to look for what shipped:

- #30 proposed **one mask covering both zones and taps**, assigned per
  import batch. That is the design D5 rejects; the zone/tap split replaced
  it after the undo hazard was found.
- #30 proposed the **matched edge bearing** for the rider side and the
  segment chord only as a desk-tool fallback. One rule (the chord) replaced
  both, which is what makes D6 exact.
- #30 claimed the latch would absorb a one-sample course reversal. It does
  not — `RouteEventTracker`'s directed gate drops the event first. D4 states
  the real scope, and corroboration was added for the failure the original
  latch actually had.
- #30 listed "removing a segment on re-import" as out of scope, inheriting
  `marker_count`'s inability to clear. The zone/tap split made clearing
  trivial and correct, so D5 does it: import replaces, as webmap.dev's own
  contract always said it should.

## Consequences

- A rider can express "this squeeze only matters going this way," which is
  the case hand-drawn zones exist for and the only way two zones on one road
  can be told apart.
- **NFR-001 is preserved in the direction that matters.** Every degenerate
  or uncertain case applies the record rather than withholding it, so the
  gate can add a redundant `HEAD_UP` but never silence a zone on thin
  evidence. The one path that could suppress — a mis-latched direction — is
  what D4's corroboration exists to bound.
- **NFR-003 is preserved:** the gate is upstream of the trace's resolved
  input, and both resolvers are pure functions of their inputs.
- **NFR-005 is unchanged:** one byte of direction per remembered segment, no
  timestamps, no coordinates.
- Bidirectional zones, in-ride marker taps, and every pre-RFC file and store
  behave exactly as before.
- **One upgrade gap, documented rather than fixed.** Segments imported by the
  PRE-RFC app carry `marker_count` and no mask, so D5's departure check
  cannot see that a zone put them there: removing such a segment from the
  file and re-importing leaves it flagged. Unfixable in the store —
  `marker_count` conflates old imports with in-ride taps, and clearing it
  wholesale would delete the rider's own markers. Bounded to segments
  imported before the upgrade, and conservative in direction (an extra cue,
  never a missed one).

## Out of scope

- **Directional in-ride marker taps.** The same coming-and-going problem
  applies to a tap, and D5's field would carry it — but a tap anchors to a
  look-back window sample (`RideEngine.markerAnchorWindow`), so attributing
  a direction to it is a separate, fuzzier question.
- **Directional derived squeeze zones.** Those come from `SqueezeScorer`,
  not the rider; direction would have to come from OSM tags (`oneway`,
  side-of-road), a different problem.
- **Per-zone tolerance in the file.** One global constant first (D3); a
  per-zone override is only worth it if field riding shows 90° is wrong.
