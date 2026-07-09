# ADR-0014: TACOS Selection — GitHub-Actions-Native GitOps with Native S3 State Locking

> **Note** (2026-07-09): Amended by
> [ADR-0016](0016-module-extraction-and-two-repo-topology.md) (decision 9):
> CI becomes two-repo — the extracted `terraform-talos-cluster` module repo
> runs its own CI/e2e while this repo remains the sole GitOps consumer of the
> single production workspace. Native S3 locking (`use_lockfile`) is
> load-bearing across all production-state writers (consumer CI applies and
> the operator's local upgrade-mode applies share no Actions concurrency
> domain). The dflook selection itself is unchanged. See #340 for the
> reconciliation sweep.

## Status
Accepted

## Date
2026-07-08

## Context

The project needs a TACOS-style (Terraform/OpenTofu Automation and Collaboration Software) workflow:

- **GitOps flow**: `tofu plan` posted on pull requests, `tofu apply` gated on review/merge
- **Drift detection**: scheduled comparison of live infrastructure against configuration, with notification

Hard constraints:

- **Scale**: solo / 1–2 people, a handful of workspaces (this repo; possibly future Hetzner targets)
- **Budget**: ~zero; free tier or free forever
- **Open source strongly preferred**
- **No self-hosted control plane** (no extra infra to babysit)
- **OpenTofu-native** (first-class support, not an afterthought)
- **No HashiCorp/IBM dependency** — the BSL relicensing and the IBM acquisition rule out HCP Terraform and anything that requires the BSL-licensed Terraform binary

### Prior attempt: OpenTaco

An initial attempt used OpenTaco (the Digger project, renamed 2025-11-07; the company remains "Digger, Inc."). Its GitHub App was installed but never configured, and posted a config error on every PR (#254). Evaluation concluded the platform is two very different things:

- The **PR-automation engine** is battle-tested and actively maintained (~5000 stars, 438 releases, MIT core).
- The **platform layers** are immature: Remote Runs are explicitly marked *Beta*; the Statesman state backend's own README documents that business endpoints "intentionally return Not Implemented" and that it **falls back to in-memory storage when S3 init fails** — a state-loss footgun; backendless mode silently ignores `apply_requirements` other than `mergeable` (diggerhq/digger#2073); a drift false-positive issue (#1667) has been open since 2024; OpenTaco Cloud has no public pricing page. There was also a 2025-09 incident of code copied from the OTF project without attribution (publicly apologized for).

For a 1–2 person repo, Digger in backendless mode offers little over plain GitHub Actions while adding undocumented pitfalls.

### The 2026 TACOS pricing landscape

Mid-2026 pricing collapsed the commercial options for small teams:

- **HCP Terraform**: legacy Free plan reached end of life 2026-03-31 (excluded anyway — HashiCorp/IBM)
- **env0**: removed its perpetual free plan (30-day trial only; paid from ~$1500/mo)
- **Spacelift**: entry paid tier is now Starter+ at ~$20,000/yr — and drift detection starts there, on private workers only

### State locking on OVH

Historically OVH Object Storage supported no state locking (no DynamoDB equivalent; no S3 conditional writes) — backend.tf documents this and ADR-0010 relies on process controls. This changed: OVH shipped S3 conditional writes (`If-None-Match`, public-cloud roadmap issue #671), and an OVHcloud blog tutorial (2026-06-15, Aurélie Vache) demonstrates working native locking (`use_lockfile = true`, `.tflock` object, `412 PreconditionFailed` on concurrent apply) on OVH Object Storage with both Terraform and OpenTofu. OpenTofu ≥ 1.10 supports this natively, removing any need for DynamoDB.

The demo used a 3-AZ bucket in `eu-west-par` (new-generation `io.cloud.ovh.net` endpoints); availability on older regions/storage classes must be verified empirically per bucket (#278).

## Considered Options

| Option | Cost (solo) | License | Hosting | OpenTofu | Drift detection | Verdict |
|---|---|---|---|---|---|---|
| **dflook GitHub Actions** | Free | MIT | Actions-native, no server | First-class (`tofu-*` actions) | `terraform-check` on cron (DIY notification) | **Selected** |
| **Terrateam** | Free forever tier | MPL-2.0 | SaaS (GitHub App) | First-class | Free: 1 schedule/repo; more = paid | Runner-up |
| **Scalr** | Free ≤ 50 runs/mo | Proprietary | SaaS | First-class (OpenTofu founding member) | Free (drift runs don't count against quota) | Viable at scale; SaaS takes over workflow |
| **Digger / OpenTaco (backendless)** | Free | MIT core / EE | Actions-native | First-class | Detection only; **remediation not implemented backendless** | Rejected (platform immature, silent gaps) |
| **Spacelift** | Free 2 users | Proprietary | SaaS | First-class | Only from ~$20k/yr, private workers | Rejected |
| **env0** | No free tier (2026) | Proprietary | SaaS | First-class | Paid | Rejected |
| **Atlantis** | Free | Apache-2.0 | **Self-hosted** | Yes | **None built-in** | Rejected |
| **Terrakube** | Free | Apache-2.0 | **Self-hosted K8s** | Yes | Yes | Rejected (control plane to run, small community) |
| **Burrito** | Free | Apache-2.0 | **Self-hosted K8s** | Yes | Continuous (ArgoCD-style) | Rejected (extra infra) |

## Decision

**GitHub-Actions-native GitOps built on `dflook/terraform-github-actions`, with state remaining on OVH Object Storage using OpenTofu ≥ 1.10 native S3 locking.**

1. **Plan on PR** — `dflook/tofu-plan` posts/updates the plan as a PR comment (#279)
2. **Apply on merge** — `dflook/tofu-apply` applies the PR-approved plan after merge to `main`, and fails if the plan changed since review (#279)
3. **Drift detection** — `dflook/terraform-check` on a daily cron; failure opens/updates a GitHub Issue (and/or Slack webhook) (#279)
4. **State locking** — `use_lockfile = true` in the s3 backend (requires bumping `required_version` to `>= 1.10.0`); keep `skip_s3_checksum = true` (newer AWS SDK checksums break non-AWS S3 implementations — the same flag keeps a future Hetzner migration working, per opentofu/opentofu#2605); bucket versioning stays on as the state-recovery safety net (#278)
5. **CI-level serialization regardless of locking** — a GitHub Actions `concurrency` group with `cancel-in-progress: false` on apply/drift workflows. This is the fallback if the bucket's region turns out not to support conditional writes (`NotImplemented` instead of `412`), and belt-and-braces even when it does
6. **OpenTaco abandoned**; the `opentaco-cloud` GitHub App is uninstalled (#254, #279)

This complements — does not supersede — ADR-0006 (S3-compatible remote state) and ADR-0010 (OVH Object Storage migration): the backend stays exactly where it is, gaining locking.

### Escalation thresholds

Revisit this decision when any of these hold:

- **> 2 people** with parallel PRs needing real concurrency/queueing → **Terrateam** (free tier, BYO-S3 keeps migration minimal)
- **Multiple drift schedules** (e.g. different cadence per environment) → Terrateam paid or Scalr
- Fleet view / RBAC / multiple workspaces at scale → Scalr free tier (≤ 50 runs/mo, drift runs uncounted), accepting a SaaS-managed workflow

## Consequences

**Positive:**

- Zero cost, zero servers: the repo is public, so GitHub Actions minutes are unlimited
- MIT-licensed, provider-agnostic building blocks; no HashiCorp/IBM anywhere in the chain
- Native S3 locking simplifies the story ADR-0010 had to work around — no DynamoDB, no process-control-only discipline
- A future Hetzner migration is an endpoint/bucket change (same `skip_s3_checksum` caveat applies there)

**Negative / accepted risks:**

- **Credentials in GitHub**: plan/apply/drift in CI require backend S3 credentials plus provider credentials (OVH API, Tailscale OAuth, Shodan) as Actions secrets. OVH S3 has no OIDC federation, so these are static keys — least-privilege scoped, stored in the `production` environment with deployment protection. This is the same decision #258 (cluster-checks credentials) was parked on; they are decided together (#279)
- **GitHub Actions reliability**: 57 outages May 2025–Apr 2026 (IncidentHub) — the whole flow inherits this; acceptable for this project's scale
- **Drift detection blind spots**: `tofu plan` only detects drift in managed resources and provider-read attributes — inherent to every tool evaluated
- Single drift schedule and DIY notifications (vs. a product dashboard); accepted at this scale
- Pricing/tier data is a mid-2026 snapshot and shifts quickly; thresholds above matter more than vendor names

## References

- Research: TACOS comparison for xd-ventures, July 2026 (Atlantis, Digger/OpenTaco, Terrateam, Burrito, Scalr, Spacelift, env0, Terrakube, Terramate)
- [dflook/terraform-github-actions](https://github.com/dflook/terraform-github-actions) — `tofu-plan`, `tofu-apply`, `terraform-check`
- OVHcloud blog (2026-06-15, Aurélie Vache): native S3 state locking on OVH Object Storage; OVH public-cloud roadmap issue #671 (conditional writes / `If-None-Match`)
- [OpenTofu S3 backend `use_lockfile`](https://opentofu.org/docs/language/settings/backends/s3/) (OpenTofu ≥ 1.10); [opentofu/opentofu#2605](https://github.com/opentofu/opentofu/issues/2605) (`skip_s3_checksum` for non-AWS S3)
- [diggerhq/digger#2073](https://github.com/diggerhq/digger/issues/2073) (`apply_requirements` ignored in backendless), [diggerhq/digger#1667](https://github.com/diggerhq/digger/issues/1667) (drift false positives)
- IncidentHub: GitHub outages May 2025–April 2026
- Related: #254 (OpenTaco app closed invalid), #277 (this ADR's ticket), #278 (locking migration), #279 (dflook workflows), #258 (CI credentials decision)
