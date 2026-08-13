# RFC 0003: iOS Prototype Architecture (Phase 1 Vertical Slice)

- **Status:** Accepted
- **Date:** 2026-07-09
- **Closes:** #16

## Context

Phase 1 of the roadmap is the vertical slice: ride logging, composite
squeeze-zone events, cue policy, watch haptic, marker capture, after-ride
review, and trace export (FR-001…FR-009). The kernel and the replay harness
(Phase 2 spine) are already merged, so the app's job is precisely bounded: be
a **trace producer with a haptic side effect** — everything it logs must
replay divergence-free through `replay_cli` (NFR-003), and everything the
rider feels must come from the same kernel the harness verifies.

Spec §9.1 fixes the runtime split: GPS cleanup, map matching, route-event
generation, squeeze scoring, cue-policy execution, logging, and review are
**phone-side**; the watch delivers one low-distraction haptic (§5.7); only
normalized samples, compact route events, and the kernel migrate to MCU
later. The decisions below were made interactively with the operator on
2026-07-09; hand-authored route data was explicitly rejected — route events
must derive from real map data from day one.

## Decisions

### D1 — Route events: on-device generation from an imported OSM snapshot

| Option | Verdict | Why |
| --- | --- | --- |
| **On-device from OSM region snapshot** | **Chosen** | Conforms to spec §9.1 (route-event generation is phone-side); rides work offline; location data never leaves the device (NFR-005); import-time parsing keeps per-ride cost near zero. |
| Offline Mac preprocessing tool | Rejected | Automated but moves route-event generation off the phone, bending §9.1, and adds a second toolchain. |
| Live Overpass API per ride | Rejected | Network dependency before every route, rate limits, and non-reproducible event generation across rides. |
| Apple MapKit data | Rejected | No lane counts, cycleway/shoulder tags, or widths — the core inputs to the §7 reasons bitmask. |
| Hand-authored route packs | Rejected | Operator decision: no hand-authored data; the pipeline must demonstrate real map-data fusion from day one. |

The app imports an OSM region extract once (offline-maps style). At **import
time** — not per-ride — it parses ways/tags into road **segments** and
scores **composite squeeze-zone events** from the §7 evidence: lane count,
`cycleway=*`, shoulder, `maxspeed`, width tags. Scoring produces
`RouteEvent` severity / confidence / reasons exactly as the kernel consumes
them. The parsed result is cached locally; re-import refreshes it.

**Segment-id stability across re-imports:** traces, markers, reviews, and
the RFC 0002 memory store are all keyed on `segment_id`, so ids must not be
assigned positionally (a re-import would silently orphan every historical
association). Ids are **content-derived** — deterministic from
`(osm_way_id, split_sequence)` — so re-importing the same region yields
identical ids for unchanged geometry; when upstream OSM edits change a way,
its derived ids change and any memory keyed to the old ids reverts to
`neutral` — the conservative failure direction (NFR-001, and RFC 0002's
eviction semantics). The derivation must never produce id 0 (reserved,
RFC 0002 D5): prefer a reversible encoding of `(osm_way_id,
split_sequence)` over a lossy hash; if hashing is unavoidable, a computed
0 remaps to a fixed non-zero constant, and the importer runs a
**collision audit** over the whole region — duplicate ids fail the import
loudly rather than silently merging two segments' histories. Scoring heuristics and their calibration are implementation
scope (follow-up issue), but the layer boundary — raw OSM in, kernel-shaped
`RouteEvent`s out, all on-device — and the id-stability policy are decided
here.

### D2 — Map matching: nearest segment + heading gate + hysteresis

GPS fixes match to segments by distance-to-polyline over a spatial index of
the imported segments, gated by heading agreement, with hysteresis so the
match does not flap at intersections. Deterministic, cheap, debuggable
directly from logged traces. Known weakness — parallel nearby roads — is
acceptable for the Phase 3 field loops; probabilistic (HMM/Viterbi) matching
is deliberately deferred until a field trace demonstrates the need.
Route-locked matching was rejected because it breaks ride-anywhere.

**Matcher output is trace-first-class (NFR-003):** the trace records the
matched `segment_id` per sample and the observed `RouteEvent`s per step —
exactly the existing FR-010 schema contract — and `replay_cli` feeds those
recorded values to the kernel, **never re-matching or re-scoring**. This is
what keeps the divergence-free guarantee immune to matcher changes and OSM
re-imports: replay replays what the ride saw, not what today's map would
say.

### D3 — Kernel embedding: SPM C target, no Swift mirror

`kernel/cue_policy.c` + `.h` are wrapped as a Swift Package **C target**; the
app calls `cue_policy_step` through C interop behind a thin Swift façade.
One source of truth by construction — a Swift port was rejected because it
manufactures exactly the live/replay divergence CLAUDE.md defines as a bug
and doubles every kernel change. A bridging header would also work but loses
the versioned-module hygiene of a package. The same files continue to
compile standalone for MCU targets (NFR-004); the package is packaging only,
no source changes.

### D4 — Watch cue path: WCSession `sendMessage` with fallback, budgeted

During a ride the watch app holds a workout/extended-runtime session; the
phone pushes `HEAD_UP` via `WCSession.sendMessage` (sub-second when
reachable) and falls back to `transferUserInfo`/local notification when not.
The watch plays the single subtle tap (`WKInterfaceDevice.play`, §5.7).

**Latency budget (measured, not assumed):** delivery latency eats directly
into the 5–15 s notice window, so Phase 1 includes a measurement — log
dispatch and delivery timestamps per cue. If p95 delivery exceeds **2 s**,
bias `min_notice_s` upward to compensate — as a **manual, between-rides
config change** through the normal §13 tuning loop, recorded in the trace's
`policy_config` like any other tuning. Never a runtime auto-adjustment: the
kernel's config must match what the trace records, or replay diverges
(NFR-003).

**Stale-cue expiry (NFR-001):** the fallback path queues — on reconnect,
`transferUserInfo` delivers everything at once, and a burst of taps a minute
after the squeeze zone is worse than no tap. Every cue payload carries
`dispatch_ts` and `expires_after_s = lead_time_s` — the decision's own
computed lead time, i.e. the cue expires exactly when the rider reaches the
event start. `dispatch_ts` is anchored to the **kernel step's decision
instant on the phone** (the wall-clock time of the sample that produced the
cue), not the WCSession send time — phone and watch must share this anchor,
or queueing delay before send would silently extend the expiry window. The two failure modes are asymmetric and this picks the right
side of each: a cue delivered before arrival still helps (played), one
delivered after arrival is stale noise (discarded — NFR-001 prefers a missed
cue over a misleading one). The watch discards expired cues instead of
playing them, and a dropped cue is logged as undelivered so §13 tuning sees
it.
Notification-mirroring-only was rejected (uncontrolled latency, cue arrives
dressed as a banner — against the low-distraction principle); a standalone
watch pipeline was rejected for Phase 1 (duplicates the stack on a
battery-constrained device, contradicts §9.1) but remains the natural
Phase 4+ shape.

### D5 — Marker capture: voice App Intent AND watch button (FR-006)

Both inputs from day one, writing the identical marker record (timestamp,
nearest segment per the schema's `markers[]`; heading and speed are **not
duplicated into the marker record** — they are recovered from the collocated
`RideSample` at the marker's `t_ms`, and GPS appears only in debug exports),
each confirmed
with one tap/sound (§5.8):

- **Voice** — "unsafe here" App Intent (Siri), the spec's recorded choice:
  hands stay on bars, eyes stay up.
- **Watch button** — large tappable control on the ride screen, covering
  voice's failure mode (wind/traffic noise).

Rationale for both: missed markers are lost training data for the 3–10 ride
study, and personal route memory (RFC 0002) treats explicit markers as the
dominant signal — capture reliability outranks slice thinness here. Deferring
markers was rejected: FR-006/FR-007 are in the Phase 1 requirement set.

### D6 — Verification: simulator GPX playback with the replay harness as oracle

The E2E story runs before any physical ride: simulated GPX rides drive the
full pipeline (CoreLocation → matching → events → kernel → cue log) against
real imported OSM data for the test region, asserting (a) cue timing lands
inside the notice window and (b) **the exported trace replays
divergence-free through `replay_cli`** — the harness is the app's oracle, so
live/replay divergence (the bug class CLAUDE.md names) is caught in the
simulator, not in traffic. This matches the repo's test priority: exercise
what the rider experiences, not implementation details. Unit tests still
cover the OSM importer and matcher, but the GPX round-trip is the gate.

Known limitation: the oracle is partially circular in two ways. A
schema-interpretation bug shared by app and harness passes the round-trip;
the harness's hand-computed fixture suite (`make -C replay test`) and the
kernel unit tests are the independent legs there. And because replay never
re-scores (D2), **squeeze-scoring bugs are invisible to the round-trip
entirely** — the scorer (follow-up #3) therefore requires its own fixture
tests: small OSM extracts with hand-computed expected `RouteEvent`s.
Accepted for Phase 1 with those two independent legs in place.

### D7 — After-ride review: minimal in-app grading list (FR-008)

Post-ride screen: chronological list of cues (and markers), four grading
buttons per cue — `useful` / `false_alarm` / `too_late` / `unrecognized`
(§5.9). Markers (FR-006's live "unsafe here") already carry their own
location and ride alongside the cue list as the rider's ground truth for
risk the policy never cued — no separate after-the-fact entry point is
needed for that case. Grades write `reviews[]` into the trace before
export, closing the tuning loop on-device while recollection is fresh. Mac-side grading was rejected (stale-memory
labels degrade the §13 metrics); map visualization is deferred to Phase 3
when the case study needs figures.

### D8 — Deployment targets: latest stable on the operator's devices

Single-rider field prototype: deployment targets pin to whatever the
operator's iPhone and Watch run at implementation time (recorded in the
Xcode project, revisited only if a second test device appears). Newest
background-location / App Intents / WatchConnectivity APIs without
availability-check noise; broad compatibility serves no one here.

## Consequences

- The app gains three phone-side subsystems ahead of any UI polish: **OSM
  import + squeeze scoring** (D1), **matcher** (D2), and the **ride engine**
  (kernel façade + logging + watch link). D1 is the largest and least
  de-risked — it is the first implementation issue for a reason.
- **NFR-003 end-to-end:** the same kernel binary logic runs live (D3) and in
  replay; D6 makes the equivalence a tested property, not an intention.
- **D3 constrains the kernel's public surface:** the SPM C target needs a
  `module.modulemap`/umbrella header, and everything in `cue_policy.h` must
  stay C99-compatible for Swift interop *and* MCU toolchains — future kernel
  API additions inherit this from D3, not only from NFR-004.
- **NFR-005:** OSM snapshot, matching, scoring, memory, and traces all stay
  on-device; nothing leaves except an explicitly exported trace. An exported
  ride carries ~3,600 GPS fixes per hour, so export defaults matter: the
  exporter emits **policy-tuning traces without `lat_e7`/`lon_e7`** (the
  schema already makes them optional for exactly this — the kernel replays
  from `t_ms`/`speed_cmps`/`segment_id`), and full-GPS export is a separate
  debug option for map-matching inspection, intended for the operator's own
  machine, not for sharing.
- **Latency is a first-class metric** (D4): cue delivery timestamps join the
  trace so §13 tuning sees delivery lag, not just kernel lead time.
- **Scope accepted:** real OSM parsing/scoring in Phase 1 is meaningfully
  more work than a fixture-driven slice — the operator chose realism over a
  thinner slice, and D6's simulator loop is what keeps that tractable.
- **No safety claims** (§3): the app presents cues as attention aids;
  nothing here changes that.

## Follow-up implementation issues to file

*(Titles + one-line scope; not created by this RFC.)*

1. **`ios: Xcode project skeleton + SPM kernel package (D3, D8)`** — app +
   watch targets, CueKernel package wrapping `kernel/`, façade, CI hook for
   the project's build/test commands in CLAUDE.md.
2. **`ios: OSM region import + segment model (D1a)`** — extract parsing,
   segment derivation with stable ids, local cache.
3. **`ios: composite squeeze-zone scoring (D1b)`** — §7 evidence bits →
   severity/confidence heuristics, calibration notes, and independent
   fixture tests (small OSM extracts with hand-computed expected
   `RouteEvent`s — see the D6 circularity limitation).
4. **`ios: map matcher — nearest segment + heading + hysteresis (D2)`** —
   spatial index, matcher, unit tests on synthetic geometries.
5. **`ios: ride engine — sampling, kernel façade, trace writer (D3, FR-001…003, FR-009)`** —
   1 Hz sample loop, `cue_policy_step` integration, schema-v1 trace export.
6. **`ios: watch link + haptic cue + latency measurement (D4, FR-004…005)`** —
   WCSession plumbing, workout session, tap, dispatch/delivery timestamps.
7. **`ios: markers — App Intent + watch button (D5, FR-006…007)`** — both
   inputs, one record shape, confirmation feedback.
8. **`ios: after-ride review list (D7, FR-008)`** — grading UI, reviews[]
   into the trace.
9. **`ios: GPX playback E2E harness (D6)`** — simulator scenario runner,
   notice-window assertion, replay_cli round-trip check.
