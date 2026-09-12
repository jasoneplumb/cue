# RFC 0009: Rider-Asserted Meaningful Absence

- **Status:** Implemented (PR #39)
- **Date:** 2026-09-11
- **Tracking:** #38
- **Amends:** the §7 meaningful-absence qualification rule (`SqueezeScorer`);
  builds on RFC 0002 D5 and RFC 0008 D5

## Context

The squeeze scorer treats an untagged riding space as evidence of "none"
only when the segment's highway class is well-covered by riding-space tags
in the region (`meaningfulAbsenceCoverage`, 25% — obs00004). On a sparsely
tagged class, silence means nothing and the segment does not score.

That gate collided with the custom-zone overlay's documented purpose. A
rider-drawn zone lands in personal route memory (RFC 0008 D5), but memory
can only *promote* an event the scorer already produced (RFC 0002 D5) — it
cannot conjure one. So on exactly the roads the overlay exists for — real
squeezes on roads OSM never surveyed — a drawn zone was inert: the scorer
rejected the segment, no route event was generated, and the rider's
assertion never reached the kernel.

This RFC decides how a rider's drawn zone participates in scoring, and what
confidence such a zone carries.

## Decisions

### D1 — A drawn zone substitutes for missing coverage evidence, nothing more

`SqueezeScorer.score` accepts a rider-asserted segment through the
meaningful-absence gate **only in the untagged case**. The substitution is
deliberately narrow:

- It stands in for *missing* evidence, never contradicts *present*
  evidence. A segment tagged `dedicatedSpace` still returns nil however
  emphatically the rider drew over it.
- The class, lane, and speed gates are untouched. A drawn zone on a
  residential street, a four-lane arterial, or a 30 mph road still does
  not score — the zone answers only the riding-space question, because
  that is the only question the rider's drawing addresses.

The alternative — letting a drawn zone score unconditionally — was
rejected: it would turn the overlay into a free-form cue editor and bypass
every §7 evidence bit, with no path back once riders depend on it.

### D2 — Rider-asserted confidence equals meaningful-absence confidence

`confidenceRiderAsserted` is **defined as** `confidenceMeaningfulAbsence`
(not merely set to the same number): the rider's drawing substitutes for
the coverage evidence that is missing, so it earns exactly the confidence
that evidence would have earned. It does not become a survey —
`confidenceExplicit` remains reserved for tagged `explicitNone`.

The intended ordering is therefore:

```
confidenceExplicit (190)  >  confidenceMeaningfulAbsence == confidenceRiderAsserted (165)
```

Expressing the equality in code, not as a duplicated literal, is
load-bearing: a §13 calibration pass that moves `confidenceMeaningfulAbsence`
moves both, and cannot silently leave rider-drawn zones cueing at *higher*
confidence than coverage-qualified absence.

### D3 — The scorer explains inertness instead of hiding it

"My drawn zone does nothing" has several distinct causes with distinct
remedies (redraw it, edit OSM, accept the scorer's judgment, nothing).
`rejectionReason` reports, per segment, why `score` returned nil, and the
desk exporter surfaces it per zone — diagnostics only, no caller branches
on it. Without this, D1's narrowness is indistinguishable from a bug.

## Consequences

- **NFR-001 trade-off, stated:** the rider-asserted path deliberately
  trades a little of the "missed coverage is preferable" posture for
  honoring an explicit personal assertion — but only within the §7
  conjunction (arterial class, ≤2 lanes, ≥40 mph), and only where OSM is
  silent. The rider can add a cue only on a road that already looks like a
  squeeze except for tagging; they cannot silence one, and at most one
  `HEAD_UP` per route event still holds.
- **NFR-003/NFR-004 unaffected:** the change is entirely phone-side
  scoring; `kernel/` and the replay schema are untouched.
- **NFR-005 unaffected:** no new stored data — the store's existing
  `unsafe_dir_mask` (RFC 0008 D5) is the assertion's single source of
  truth; `zoneAssertedSegmentIDs` derives the scorer's input from it.
- Re-scoring runs on every custom-zone import (import replaces, per
  RFC 0008 D5), so adding or deleting a zone takes effect immediately,
  not on the next region import.

## Out of scope

- **Directional qualification.** A zone's direction (RFC 0008) gates cue
  delivery at ride time; scoring qualification remains per-segment and
  direction-blind, matching the rest of the scorer.
- **Rider-asserted severity.** Severity continues to track speed only; the
  drawing carries no severity claim.
