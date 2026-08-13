# cue — Project Instructions

Context-aware cycling safety cue: iPhone + Apple Watch prototype with a
portable C cue-policy kernel and an MCU migration path. Conventions adapted
from infobento.com.

## Quality Gate

```bash
make -C kernel test   # build + run kernel unit tests (-Wall -Wextra -Werror -pedantic)
make -C replay test   # build replay harness + replay checked-in traces (FR-010)
swift test            # CueKernel package facade tests (macOS host)
xcodebuild -project ios/Cue.xcodeproj -scheme Cue \
  -destination 'generic/platform=iOS Simulator' \
  CODE_SIGNING_ALLOWED=NO build   # iOS app + embedded watch app (local Mac only)
```

The `xcodebuild` step needs the iOS and watchOS simulator platforms
installed in Xcode; CI runs `swift test` only. There is no lint/format gate
for C, Swift, or markdown; state that explicitly rather than claiming
success.

## Repository Structure

```
cue/
├── docs/rfcs/            Architecture decision records (NNNN-title.md)
├── ios/                  iPhone + Watch prototype (Swift): Cue.xcodeproj + CueKernel package sources
├── kernel/               Portable C cue-policy kernel + tests
└── replay/               Replay harness (replay_cli), trace schema, example traces
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

## Module Boundaries (planned)

```
kernel (pure C, no deps)  <──  replay (feeds traces through kernel)
        ^
        └──  ios (executes the same policy live; exports traces)
```

- `kernel` imports nothing; compiles standalone.
- `replay` depends only on `kernel` and the trace schema.
- `ios` embeds `kernel` (or mirrors it exactly until embedded) — divergence
  between live and replay decisions is a bug.

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
