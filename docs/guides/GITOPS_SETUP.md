# GitOps Setup (dflook workflows)

Implementation of [ADR-0014](../adr/0014-tacos-selection.md): plan-on-PR,
apply-on-merge, and scheduled drift detection via
[dflook/terraform-github-actions](https://github.com/dflook/terraform-github-actions)
(`tofu-*` actions), with state on OVH Object Storage using native S3 locking
(`use_lockfile`, see #278).

## Workflows

| Workflow | Trigger | What it does |
|----------|---------|--------------|
| `tofu-plan.yml` | PRs to `main` | Posts/updates the `tofu plan` as a PR comment |
| `tofu-apply.yml` | Push to `main` (`*.tf`, `templates/`, lockfile) | Applies the plan approved on the merged PR; **fails if the plan changed since review** — re-run after re-approval |
| `tofu-drift.yml` | Daily 06:30 UTC + manual | `tofu-check`; on drift opens/updates a `drift`-labeled issue, auto-closes it when drift clears |

`tofu-apply` and `tofu-drift` share the `tofu-state-ops` concurrency group
(`cancel-in-progress: false`) so state-mutating operations are serialized at
the CI level — belt-and-braces on top of the native S3 lock.

## Enabling (operator checklist)

The workflows are **inert until you flip the switch**: every job is gated on
`vars.GITOPS_ENABLED == 'true'`.

1. Populate the **`production` environment secrets** (Settings → Environments
   → production → Secrets):

   | Secret | Content |
   |--------|---------|
   | `AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY` | S3 credentials for the state bucket — create a **dedicated least-privilege user** scoped to the bucket, not your personal keys |
   | `BACKEND_TFVARS` | Verbatim contents of your local `backend.tfvars` |
   | `TERRAFORM_TFVARS` | Verbatim contents of your local `terraform.tfvars` (keep in sync when you change it!) |
   | `OVH_APPLICATION_KEY` / `OVH_APPLICATION_SECRET` / `OVH_CONSUMER_KEY` | OVH API credentials (see the [BYOI guide](OVH_BYOI_GUIDE.md#required-api-permissions) for the minimum access rules) |
   | `TAILSCALE_OAUTH_CLIENT_ID` / `TAILSCALE_OAUTH_CLIENT_SECRET` | OAuth client with `auth_keys` + `devices:read` + `devices:core`; must own `tag:ci` (used by the runners) and `tag:k8s-cluster` |
   | `SHODAN_API_KEY` | Shodan API key (mapped to `TF_VAR_shodan_api_key`) |

2. Set **repository variables** (Settings → Variables):

   | Variable | Value |
   |----------|-------|
   | `OVH_ENDPOINT` | `ovh-eu` |
   | `GITOPS_ENABLED` | `true` (the master switch — set this **last**) |

3. Recommended: add a **deployment protection rule** on the `production`
   environment (required reviewer = you) if you want a manual gate before
   apply/drift runs touch the cluster.

These are the same credentials `cluster-checks.yml` needs (#258) — if you
enable GitOps, finishing the cluster-checks environment (plus its
`TALOSCONFIG`/`KUBECONFIG` secrets and `CHECK_*` variables) is marginal
extra work.

## Caveats

- **Public repo, public logs**: plan/drift output on *changes* can include
  infrastructure identifiers — tracked in #282 with mitigation options (the
  TAP redaction from #237 covers cluster-checks, not OpenTofu's own plan
  rendering). Drift runs with no drift print no diff, so steady-state
  exposure is nil.
- **Fork PRs get no plan** — GitHub withholds secrets from fork workflows.
- **`TERRAFORM_TFVARS` drift**: the secret is a copy of your gitignored
  tfvars; if you change the local file, update the secret or CI will plan
  against stale values.
- **Tailscale**: runners join the tailnet as ephemeral `tag:ci` nodes (same
  pattern as cluster-checks) because the Talos/K8s APIs are only reachable
  over Tailscale with the firewall enabled.
- Rollback: set `GITOPS_ENABLED` to `false` — all three workflows skip.
