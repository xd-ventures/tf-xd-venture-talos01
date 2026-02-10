# ADR-0013: Automated Drift Detection

## Status

Accepted

## Date

2026-02-10

## Context

This project separates CI (automated validation on PRs) from CD (manual `tofu apply`). Manual apply is intentional — bare metal operations can be destructive (server reinstall), and automated apply would be dangerous without gated approval workflows that are overkill for a solo project.

However, this creates a gap: code changes merge to `main` but are not applied to infrastructure until the operator manually runs `tofu apply`. When multiple PRs merge without an intervening apply, state drift accumulates silently. The next `tofu plan` shows unexpected changes that are confusing and harder to review.

**Concrete incident (Issue #49):** After merging 10+ PRs for publication readiness, `tofu plan` showed:
- Tailscale auth key recreation (expired 1-hour TTL — expected)
- 6 debug outputs pending removal (code changed, state not updated)
- New device lookup outputs pending addition
- Firewall config re-apply (side effect of auth key change)

None of this was dangerous, but it eroded confidence in the plan output.

## Considered Options

### Option 1: Manual-Only (Status Quo)

Rely on operator discipline to run `tofu apply` after merging.

**Pros**: Zero infrastructure, no secrets in CI
**Cons**: Silent drift accumulation, exactly the problem we're solving

### Option 2: Post-Merge Plan Check

Run `tofu plan` after every merge to `main`.

**Pros**: Immediate feedback
**Cons**: Fires on non-TF changes (docs, CI workflows), creates false urgency for intentional drift (you merged but haven't applied yet — that's expected)

### Option 3: Scheduled Drift Detection (Selected)

Run `tofu plan` on a daily cron schedule. Alert via GitHub Issue when unexpected changes are found.

**Pros**: Catches forgotten applies within 24 hours, no false positives from doc-only merges, low maintenance
**Cons**: Up to 24-hour detection delay, requires secrets in GitHub Actions, adds CI cost (~3 min/day)

### Option 4: Full CI/CD with Gated Apply

Automated `tofu apply` with approval gates (e.g., GitHub Environments).

**Pros**: Eliminates drift entirely
**Cons**: Overkill for solo project, dangerous for bare metal (reinstall triggers), complex approval workflow

## Decision

**Scheduled drift detection** (Option 3) via a GitHub Actions cron workflow.

### Key Design Decisions

- **Daily at 07:00 UTC** — operator sees results at start of day
- **Expected drift filtering** — Tailscale auth key expiry (1-hour TTL) is filtered out as known expected drift to avoid noise
- **GitHub Issues for alerting** — persistent, trackable, self-documenting
- **No duplicate issues** — workflow checks for open `drift` label issues before creating new ones; comments on existing issue instead
- **No `tofu apply` in CI** — the workflow is detection-only by construction
- **Plan output not logged raw** — state may contain sensitive values; only resource addresses and actions are reported

### Workflow

```
Cron (daily) → tofu init → tofu plan -detailed-exitcode
  → exit 0: no changes (Job Summary: "all clean")
  → exit 1: error (workflow fails)
  → exit 2: changes detected → analyze plan JSON
    → all expected: Job Summary only
    → unexpected: create/update GitHub Issue with drift label
```

## Consequences

### Positive

- Drift detected within 24 hours
- Self-documenting issues with change details and next steps
- Expected drift (auth key) filtered out — low noise
- Manual apply workflow preserved (no automation risk)

### Negative

- Requires 7+ GitHub Secrets for provider credentials
- ~3 min/day of GitHub Actions compute
- 24-hour detection delay (acceptable for solo project)
- No state locking on OVH S3 — concurrent local apply could cause stale reads (low probability for solo operator)

## References

- Issue #49: State drift detection
- [OpenTofu `-detailed-exitcode`](https://opentofu.org/docs/cli/commands/plan/)
- ADR-0006: Remote State Backend
- ADR-0012: Single-Node Destructive Upgrades (manual apply rationale)
