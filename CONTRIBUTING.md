# Contributing to cue

## Prerequisites

- **Git** — version control
- **Xcode 16+** — for `ios/` (Phase 1+)
- **A C compiler** (clang) — for `kernel/` and `replay/` (Phase 1+)

## Development Workflow

### 1. Create a Feature Branch

```bash
git checkout mainline
git pull origin mainline
git checkout -b feature/your-feature-name
```

**Branch naming:**

- `feature/` — New features
- `fix/` — Bug fixes
- `refactor/` — Code restructuring
- `docs/` — Documentation updates
- `test/` — Test additions

### 2. Make Your Changes

**Before coding:**

1. Check `docs/rfcs/` for the decision records that define current design
2. Reference requirement IDs (FR-xxx / NFR-xxx) in commits and PRs — they
   come from the project's design record (kept in the private archive) and
   are used consistently across the docs

**While coding:**

- Add intent headers to new files (Intent, Context, Pattern, Future)
- Document non-obvious decisions with `// tradeoff:` or `// constraint:` comments

### 3. Run Quality Checks

```bash
make test     # kernel, replay, MCU host tests + the minimal example
swift test    # CueKernel package facade (macOS host)
```

CI additionally runs schema validation, ASan/UBSan + a fuzz smoke, and the
cross-architecture equivalence job. There is no lint/format gate for C,
Swift, or markdown (`.clang-format` is advisory) — say so in the PR rather
than claiming a gate that does not exist.

### 4. Commit Your Changes

Use **conventional commit** format: `<type>(<scope>): <description>`

**Types:** `feat`, `fix`, `docs`, `style`, `refactor`, `test`, `chore`, `perf`, `ci`, `build`, `revert`

**Examples:**

- `feat(kernel): implement cue-policy gate (FR-004)`
- `feat(ios): background ride logging (FR-002)`
- `docs(rfcs): record trace schema versioning decision`

### 5. Push and Create PR

**PR Checklist:**

- [ ] PR is focused on a single feature or fix
- [ ] Requirement IDs referenced where applicable
- [ ] Documentation / CHANGELOG.md updated if behavior changed
- [ ] Intent headers on new files

### 6. Request a Claude Review

Add the `review-requested` label to trigger the automated Claude review — as a
separate step _after_ creating the PR (folding it into `gh pr create` suppresses
the `labeled` event the workflow listens for):

```bash
gh pr edit <N> --add-label review-requested
```

Re-trigger a review by removing and re-adding the label. The reviewer posts
inline comments plus a summary starting with `🔍 Review verdict: N findings`;
a run that posts nothing fails its check by design.

Note: PRs that modify `.github/workflows/claude-review.yml` itself cannot pass
their own review check (the action requires the workflow file on the PR branch
to match the default-branch version) — admin-merge those once `ci` is green.

## License of Contributions

cue is licensed under the [Apache License 2.0](LICENSE). Contributions
follow the inbound = outbound norm: by submitting a pull request you agree
that your contribution is licensed under Apache-2.0, per its Section 5 —
no separate CLA.
