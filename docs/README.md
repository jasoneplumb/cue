# Documentation

> _One tap before the squeeze._

The authoritative design record (source of the FR-xxx / NFR-xxx
requirement IDs) stays in the private working archive. Decisions that
supersede or refine it are the numbered RFCs below. Code-level
documentation lives inline with the code using intent headers.

---

## RFCs

| RFC                                             | Decision                    |
| ----------------------------------------------- | --------------------------- |
| [0001-project-name.md](rfcs/0001-project-name.md) | Project naming — candidates and tradeoffs |
| [0002-personal-route-memory.md](rfcs/0002-personal-route-memory.md) | Personal route memory (spec §9) — store, derivation, kernel surface, replay |
| [0003-ios-architecture.md](rfcs/0003-ios-architecture.md) | Phase 1 iOS + watchOS architecture — OSM-snapshot events, SPM kernel, watch cue path |
| [0004-perceptible-cue-haptic.md](rfcs/0004-perceptible-cue-haptic.md) | Watch haptic pattern — what a cue has to feel like to be noticed |
| [0005-phone-audible-chime.md](rfcs/0005-phone-audible-chime.md) | Phone chime as a second delivery channel |
| [0006-pico-cue-delivery.md](rfcs/0006-pico-cue-delivery.md) | Kernel-on-Pico cue delivery — BLE link, wire codec, on-target certification |
| [0007-h2-cue-miniaturization.md](rfcs/0007-h2-cue-miniaturization.md) | Miniaturized cue device — ESP32-H2, LiPo, and the loudness question |
| [0008-directional-custom-zones.md](rfcs/0008-directional-custom-zones.md) | Directional custom zones — a drawn zone applies only riding the way it was drawn |

## Engineering Docs

| Document                                                            | Purpose                                                        |
| ------------------------------------------------------------------- | --------------------------------------------------------------- |
| [eval-board-migration-matrix.md](eval-board-migration-matrix.md)     | Board-neutral evaluation-board comparison for the Phase 4 MCU migration (spec §13) |
| [../PORTING.md](../PORTING.md)                                       | Port the kernel to a new MCU/toolchain — footprint budget, tripwires, on-target certification contract |
| [mcu-replay-demo-readme.md](mcu-replay-demo-readme.md)               | Phase 4+ MCU replay-demo README draft (SAM E54, vendor-example format) |
| [provisioning.md](provisioning.md)                                   | Device-provisioning runbook (signing, capabilities, region import)     |
| [design-aspects.md](design-aspects.md)                               | Decision-layer design walkthrough — reasoning, value, tradeoffs        |
| [results.md](results.md)                                             | Aggregated field results — equivalence-contract evidence, corpus, grades, delivery (reproduce with `tools/cue-results/aggregate.py`) |
| [webmap-overlays.md](webmap-overlays.md)                             | Export→view guide for webmap.dev's overlay pair: squeeze zones (`cue-zone-export`) and per-ride cue events (`cue-events-export`) |
| [grading-guide.md](grading-guide.md)                                 | Grade cues on the map and merge the sidecar back into the ride trace (`cue-review-merge`) — the §13 tuning loop's ground truth |
| [ablations.md](ablations.md)                                         | Replay ablation sweep — policy variants re-scored against the field corpus (`tools/cue-ablation/ablate.py`); the replay harness as research instrument |
| [../tools/osm_tag_audit.sh](../tools/osm_tag_audit.sh)               | Desk-check a ride region's OSM tag coverage for the squeeze-scorer attributes (RFC 0003 D1 falsifier; run before trusting cold detection in a new region) |

## Documentation Map

```
docs/
├── rfcs/            Architecture decision records (NNNN-title.md)
└── *.md             Engineering docs (migration matrix, …)
```

**Root files:**

- `CLAUDE.md` — AI assistant project guide
- `AGENTS.md` — Concise repo guidelines for AI agents
- `AGENT_POLICY.md` — Agent constraints and policies
- `CONTRIBUTING.md` — Contribution workflow
- `SECURITY.md` — Vulnerability reporting + ride-trace data sensitivity
