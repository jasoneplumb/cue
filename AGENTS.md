# Repository Guidelines

## Project Structure

Design-record-first repo for a context-aware cycling safety cue (a
deterministic decision-layer reference demo — no learned model). The design record itself stays in the private working archive; `docs/rfcs/` holds decision records. Planned code: `ios/`
(iPhone + Watch prototype), `kernel/` (portable C cue-policy kernel), `replay/`
(trace replay harness).

## Commands

No toolchain configured yet (Phase 0). Do not claim build/test/lint success —
state that no quality gate exists until one lands. Update this file and
CLAUDE.md when it does.

## Coding Style (for future code)

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
