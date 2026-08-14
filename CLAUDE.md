# cue — Project Instructions

Context-aware cycling safety cue: iPhone + Apple Watch prototype with a
portable C cue-policy kernel and an MCU migration path. Conventions adapted
from infobento.com.

## Quality Gate

```bash
make test             # kernel + replay + MCU host tests + minimal example (root Makefile)
swift test            # CueKernel package facade tests (macOS host)
xcodebuild -project ios/Cue.xcodeproj -scheme Cue \
  -destination 'generic/platform=iOS Simulator' \
  CODE_SIGNING_ALLOWED=NO build   # iOS app + embedded watch app (local Mac only)
```

Individual gates remain runnable directly (`make -C kernel test`,
`make -C replay test`, `make -C mcu test`, `make -C examples test`).
`make demo-corpus` generates the synthetic ride corpus the analysis tools
(`tools/cue-results`, `tools/cue-ablation`) consume without field data.
CI additionally runs ASan/UBSan + a fuzz smoke (`sanitize`) and the
cross-architecture equivalence job (x86-64 / ARM32 / RISC-V, bit-exact).

The `xcodebuild` step needs the iOS and watchOS simulator platforms
installed in Xcode; CI runs `swift test` only. There is no lint/format gate
for C, Swift, or markdown; state that explicitly rather than claiming
success.

## Repository Structure

```
cue/
├── docs/rfcs/            Architecture decision records (NNNN-title.md)
├── examples/             Minimal kernel embedding (built + run in CI)
├── fuzz/                 libFuzzer harness for the trace-JSON tokenizer
├── ios/                  iPhone + Watch prototype (Swift): Cue.xcodeproj + CueKernel package sources
├── kernel/               Portable C cue-policy kernel + tests
├── mcu/                  MCU ports (pico-cue, esp32s2-cue) + on-target certification (hiltest)
├── replay/               Replay harness (replay_cli), trace schema, example traces
└── tools/                Desk tools: results aggregator, ablation sweep, demo corpus, exports
```

## Design Constraints (from the design spec)

- **Deterministic kernel:** the cue-policy kernel shall be deterministic for a
  given replay trace and policy configuration (NFR-003).
- **MCU-portable:** the kernel avoids dynamic allocation and OS-specific
  dependencies (NFR-004). C, fixed-size types (`uint32`, `int16`, …) matching
  the data model in the spec §6.
- **Conservative cueing:** at most one `HEAD_UP` cue per route event; missed
  coverage is preferable to noisy cueing (NFR-001).
- **Privacy:** store only data necessary for cue tuning and replay (NFR-005).
- **No safety claims:** never state or imply crash prevention; no medical or
  fitness claims (§3 non-goals).
- Map matching and route-event generation stay phone-side; only normalized
  samples, compact route events, and the kernel migrate to MCU.

## Module Boundaries

```
kernel (pure C, no deps)  <──  replay (feeds traces through kernel)
        ^
        ├──  ios (executes the same policy live; exports traces)
        └──  mcu (compiles the same kernel by path reference; certified
             on-target against the replay goldens — hiltest)
```

- `kernel` imports nothing; compiles standalone.
- `replay` depends only on `kernel` and the trace schema.
- `ios` embeds `kernel` — divergence between live and replay decisions is
  a bug.
- `mcu` ports never copy kernel sources; they compile the canonical files
  by path so a port cannot drift from what CI tests.

## Design Record

The authoritative requirements (FR-xxx / NFR-xxx) come from the project's
frozen July 8, 2026 design record, which stays in the private working
archive. Design changes go in `docs/rfcs/` as numbered decision records;
the requirement IDs are the shared vocabulary.

## Git & Review Workflow

- Default branch: `mainline`. Branch prefixes: `feature/`, `fix/`,
  `refactor/`, `docs/`, `test/`.
- Conventional commits: `<type>(<scope>): <description>`.
- **GitHub repo: Public** (curated mirror; the private working archive is
  `cue-archive`). Use the `review-requested` label on PRs to trigger
  Claude review (add as a separate step after PR creation).
- See `AGENT_POLICY.md` for agent constraints.
