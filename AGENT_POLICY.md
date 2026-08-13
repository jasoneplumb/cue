# Agent Policy

Explicit prohibitions and constraints for AI agent operations in this repository.

## Prohibited Actions

Agents (droids, ghosts, clones) operating in this repository **must not**:

1. **Push directly to mainline** — All changes must go through a feature/fix branch and PR.
2. **Delete GitHub issues or pull requests** — Agents may close issues but must never delete them.
3. **Modify CI/CD workflows without human review** — Changes to `.github/workflows/` require explicit human approval.
4. **Skip review when policy requires it** — When `review-required` is active, wait for approval before merging.
5. **Force-push to shared branches** — No `git push --force` to `mainline` or branches with open PRs.
6. **Modify security-sensitive files autonomously** — API keys, auth config, and encryption require human review.
7. **Bypass pre-commit hooks** — No use of `--no-verify` flag.
8. **Contradict the design record** — Design changes go in `docs/rfcs/` as decision records (the record itself lives in the private working archive).

## Policies

| Policy            | Description                                          | Merge Gate                |
| ----------------- | ---------------------------------------------------- | ------------------------- |
| `review-required` | Default. Claude-review or human approval required.   | Review approval + CI pass |
| `no-review`       | Applied when `no-review` label is present on the PR. | CI pass only              |
| `opus-delegated`  | Security-sensitive task delegated to Opus model.     | Opus review + CI pass     |

## Policy Determination

1. If the task involves security/auth/encryption -> `opus-delegated`
2. If the PR has a `no-review` label -> `no-review`
3. Otherwise -> `review-required` (default)
