# Repository Guidelines

## Project Structure

Design-record-first repo for a context-aware cycling safety cue (a
deterministic decision-layer reference demo — no learned model). The design record itself stays in the private
working archive; `docs/rfcs/` holds the decision records that refine it. Code:
`kernel/` (portable C cue-policy kernel), `replay/` (trace replay harness),
`ios/` (iPhone + Watch prototype), `mcu/` (Pico W + ESP32-S2 ports, on-target
certification), `tools/` (desk tools), `examples/` (minimal embed),
`fuzz/` (trace-tokenizer fuzz harness).

## Commands

- `make test` — kernel, replay, and MCU host test suites plus the minimal example
- `swift test` — CueKernel package facade (macOS host)
- `make demo-corpus` — synthetic ride corpus for `tools/cue-results` / `tools/cue-ablation`
- iOS app build stays a local-Mac gate (see CLAUDE.md); CI runs everything else

There is no lint/format gate for C, Swift, or markdown — state that
explicitly rather than claiming success (`.clang-format` is advisory).

## Coding Style

- `kernel/`: C, deterministic, no dynamic allocation, no OS dependencies,
  fixed-width types per the design spec data model.
- `ios/`: Swift, SwiftUI + WatchKit; keep decision logic in the kernel, not the UI.
- Intent headers on new files: Intent, Context, Pattern, Future.
- Inline decision tags: `tradeoff:`, `constraint:`, `future:`, `pattern:`.

## Commits & PRs

- Branch from `mainline` with `feature/`, `fix/`, `refactor/`, `docs/`, `test/` prefixes.
- Conventional commits enforced: `<type>(<scope>): <description>`.
- PRs target `mainline`; add the `review-requested` label after creation to
  trigger Claude review.
- Design changes go in `docs/rfcs/` as decision records.
