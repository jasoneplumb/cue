# cue

> _One tap before the squeeze._

A deterministic decision kernel with a field-enforced equivalence contract:
the same C file runs live on a phone, as an MCU actuator, and in offline
replay — and all three must agree, bit for bit, on every decision. On the
field corpus so far the contract holds over **11,300 shadow-compared
real-world steps with zero divergences**, and 23/23 recorded ride traces
replay exactly ([field results](docs/results.md); [why it's built this
way](docs/design-aspects.md)).

The demonstrator is a context-aware cycling safety cue. An iPhone + Apple
Watch prototype combines map context, GPS, rider motion, and explicit rider
feedback to warn a cyclist with one low-distraction haptic tap 5–20 seconds
**before** entering a "squeeze zone" (narrow lane, no shoulder or bike lane,
high-speed mixed traffic). After the ride, the rider grades each cue —
useful, false alarm, too late, unrecognized — and replayable traces tune the
policy offline.

The bike is the demonstrator. The reusable asset is the pipeline:

```
sensor input → feature extraction → local decision → low-latency cue
      → field logging → replayable validation → MCU migration
```

## Overview

Cyclists need attention cues before road geometry compresses their options. A
warning inside the squeeze zone is too late; a warning that fires too often is
noise. The cue policy gates on severity, confidence, and time-to-event, with
cooldown and speed suppression, and emits at most one `HEAD_UP` cue per route
event. Missed coverage is preferable to noisy cueing.

The system starts phone + wearable so the live cue loop can be field-tested
quickly. The decision layer is a deterministic, allocation-free C kernel that
replays recorded traces first and migrates to an MCU evaluation board later —
making the demo a vendor-facing decision-layer reference architecture, not
just a consumer app. There is no learned model anywhere in the pipeline: the
cue policy is a hand-written, integer-only rule gate, which is what makes its
decisions bit-exact replayable.

## Architecture

```
┌──────────────────────┐      ┌────────────────┐      ┌───────────────────────┐
│  iPhone prototype    │─────►│  Apple Watch   │─────►│  MCU migration        │
│  ride logging        │      │  one haptic    │      │  portable cue-policy  │
│  GPS cleanup / map   │      │  cue           │      │  kernel               │
│  matching            │      │  marker        │      │  replay trace harness │
│  squeeze events      │      │  confirmation  │      │  eval-board demo      │
│  cue-policy exec     │      │  low-          │      │  later: sensor pod    │
│  after-ride review   │      │  distraction   │      │                       │
│  replay trace export │      │  output        │      │                       │
└──────────────────────┘      └────────────────┘      └───────────────────────┘
        Shared spine: normalized samples + route events + cue decisions + reviews
```

Map matching and route-event generation stay phone-side in the first
architecture. Only normalized samples, compact route events, and the cue-policy
kernel move toward MCU evaluation boards.

## Repository Structure

| Path                  | Purpose                                                             |
| --------------------- | ------------------------------------------------------------------- |
| `docs/rfcs/`          | Architecture decision records                                        |
| `ios/`                | iPhone + Watch prototype: app + watch targets, SPM packages (map import/scoring, matcher, ride engine, watch link) |
| `kernel/`             | Portable C cue-policy kernel (`cue_policy.h`) + tests                |
| `replay/`             | Replay harness (`replay_cli`) + `replay_trace.schema.json` + example traces (FR-010) |
| `tools/`              | Desk tools: OSM tag audit, D6 GPX ride simulator                     |

## Roadmap

- **Phase 0 — Design record.** Establish the design record (kept in the private working archive); adopt repo conventions. _(done)_
- **Phase 1 — Vertical slice.** Ride logging, composite squeeze-zone events, cue policy, watch haptic, after-ride review, trace export (FR-001…FR-009). _(code complete — all nine RFC 0003 deliverables merged)_
- **Phase 2 — Replay loop.** Portable kernel + replay harness reproduce recorded cue decisions deterministically (FR-010, NFR-003). _(done — and verified against the first field trace)_
- **Phase 3 — Field proof.** Three-ride engineering proof, then ten-ride case study with before/after policy comparison. _(in progress — first instrumented ride captured)_
- **Phase 4 — MCU migration.** Board-neutral migration matrix _(done)_, evaluation-board demonstration _(README drafted; build pending)_.

## Documentation

See [docs/README.md](docs/README.md) for the full documentation index,
[docs/results.md](docs/results.md) for the aggregated field results
(reproducible via `tools/cue-results/aggregate.py`), and
[docs/design-aspects.md](docs/design-aspects.md) for the decision-layer
design walkthrough — seven design decisions, each with reasoning, value, and
tradeoff. The
authoritative requirements live in the project's design record, which stays
in the private working archive; its requirement IDs (FR-xxx / NFR-xxx) are
the shared vocabulary used throughout this repo and its RFCs.

To view exported rides on a map — squeeze zones plus per-ride cue events on
webmap.dev's overlay pair — see
[docs/webmap-overlays.md](docs/webmap-overlays.md). To grade the cues a ride
fired and merge the grades back into its trace, see
[docs/grading-guide.md](docs/grading-guide.md).

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md) for development workflow and guidelines.

## License

Copyright © 2026 Jason E Plumb.

Licensed under the [Apache License 2.0](LICENSE).

**BTstack note for integrators:** `mcu/pico-cue` builds against
[BTstack](https://github.com/bluekitchen/btstack) via the pico-sdk, which is
free for open-source use but requires a commercial license from BlueKitchen
for commercial products. This repository vendors only its own
`btstack_config.h` (Apache-2.0), so the repo's license is unaffected — but a
commercial firmware build inherits BTstack's terms.

## Status

The Phase 1 vertical slice is code complete: the iPhone app imports a real
OSM region, scores composite squeeze zones, matches GPS to segments, runs
the same C kernel live that the replay harness runs offline, dispatches the
haptic to the watch with measured delivery latency, captures markers by
voice and watch button, grades cues after the ride, and exports schema-v1
traces (83 package tests; app + watch build clean).

The first field trace has been captured and **replayed bit-for-bit through
`replay_cli` — NFR-003 held on real-world data**. Field measurements (cue
lead time, watch delivery p95) await the first moving ride; two
field-found gaps (background sampling across screen lock, the watch's
ride-mode workout session) are fixed. Phase 3 riding is underway; Phase 4
has a verified board matrix and a drafted demo README.

Repo conventions adapted from
[infobento.com](https://github.com/jasoneplumb/infobento.com).
