# ADR-0013: Upgrade Lifecycle Architecture

## Status
Accepted

## Date
2026-03-20

## Context

[ADR-0012](0012-single-node-destructive-upgrades.md) established a single-node deployment with reinstall-based upgrades via `ovh_dedicated_server_reinstall_task`. Every change — Talos version bump, extension update, config change, or even a Renovate dependency bump — triggers a full OVH BYOI reinstall that wipes the disk, destroys etcd, ZFS pools, and all cluster state. Recovery takes 15-30 minutes.

This approach was justified when the project had no persistent state worth preserving. As the cluster matures (ZFS data pools, ArgoCD-managed workloads, Tailscale identity), destructive upgrades become increasingly costly:

- **Issue #205**: Renovate bumping a provider version changed inline manifest hashes, triggering unnecessary reinstalls
- **Issue #157**: The ts.net DNS resolution fix required a reinstall to add `extraHostEntries`
- **Operational cost**: Every upgrade requires re-bootstrapping etcd, re-registering Tailscale, and waiting for ArgoCD to re-sync all workloads

The Talos ecosystem provides non-destructive upgrade mechanisms that the project was not using:
- `talosctl upgrade` — in-place OS/extension upgrades with A/B boot and automatic rollback
- `talos_machine_configuration_apply` — live config updates via the Talos API
- KubePrism — localhost API proxy enabling endpoint independence

### What Survives Each Operation

| Data | OVH Reinstall | `talosctl upgrade` | `apply-config` |
|------|:---:|:---:|:---:|
| etcd data | Lost | Preserved | Preserved |
| ZFS pools | Lost | Preserved¹ | Preserved |
| Machine config | Lost | Preserved | Updated |
| Inline manifests | Lost | Preserved | Updated live (no reboot) |
| Firewall rules | Lost | Preserved | Staged for reboot² |
| Running pods | Lost | Drained, restart | Preserved (no-reboot) |
| Tailscale identity | Lost³ | Preserved | Preserved |

¹ Requires `--stage` flag to avoid ZFS unmount failure ([siderolabs/talos#8800](https://github.com/siderolabs/talos/issues/8800))
² Firewall rules are `NetworkRuleConfig` documents applied by machined at boot
³ Requires cleanup of stale Tailscale device and new auth key

## Considered Options

### Option A: Keep Single Reinstall Path (Status Quo)

Every change triggers `ovh_dedicated_server_reinstall_task`. Simple mental model: `tofu apply` always converges to declared state from scratch.

**Rejected**: The cost of reinstalls now exceeds the simplicity benefit. ZFS data loss and 15-30 minute outages for a Renovate dependency bump are unacceptable.

### Option B: Replace Reinstall with `talosctl upgrade` for Everything

Remove the OVH reinstall task entirely. Use `talosctl upgrade` for version changes and `apply-config` for everything else.

**Rejected**: Cannot handle first-time deployment (no running node to connect to) or disaster recovery (bricked node). The OVH reinstall path must remain as a fallback.

### Option C: Three-Phase Lifecycle with `upgrade_mode` Variable (Selected)

Split lifecycle operations into three distinct mechanisms, each handling the operation it's best suited for. A variable controls whether version changes use the in-place upgrade path (default) or the reinstall path (first deploy, DR).

### Option D: Wait for Native Terraform Upgrade Resource

The community has requested a `talos_machine_upgrade` resource ([siderolabs/terraform-provider-talos#140](https://github.com/siderolabs/terraform-provider-talos/issues/140), 91 thumbs up, filed December 2023). There is speculation that Siderolabs is channeling this capability into their commercial product (Omni).

**Rejected**: The issue has been open for 2+ years with no implementation. We cannot wait indefinitely. The `local-exec` approach with `talosctl upgrade` is the pragmatic solution.

## Decision

Implement a three-phase upgrade lifecycle, each phase building on the previous:

### Phase 1: Live Config Updates (#209)

Add `talos_machine_configuration_apply` resource from the `siderolabs/talos` provider. This applies machine config changes to a running node via the Talos API without reinstall or reboot.

**What it handles**: Inline manifest updates (Cilium, ZFS Job), network config changes (`extraHostEntries`), certSANs, kubelet config, node labels/taints.

**Mechanism**: The Talos provider connects to the node's API and pushes the new config. Talos reconciles the difference — for `.cluster` changes (like inline manifests), this is immediate; for changes requiring a reboot (like firewall rules), it stages the config for next boot.

**Key resource**:
```hcl
resource "talos_machine_configuration_apply" "controlplane" {
  client_configuration        = talos_machine_secrets.this.client_configuration
  machine_configuration_input = data.talos_machine_configuration.controlplane.machine_configuration
  node                        = local.default_api_ip
  endpoint                    = local.default_api_ip
  apply_mode                  = "auto"
}
```

### Phase 2: In-Place OS Upgrades (#210)

Add `upgrade_mode` variable (default: `"upgrade"`) and a `terraform_data` resource that runs `talosctl upgrade --stage --preserve` via `local-exec`.

**What it handles**: Talos version bumps, extension add/remove.

**Key design decisions**:
- `--stage`: Install upgrade artifacts before ZFS mounts are active (mandatory for ZFS-on-system-disk, see [#8800](https://github.com/siderolabs/talos/issues/8800))
- `--preserve`: Keep EPHEMERAL partition (etcd data) — critical for single-node where etcd cannot rebuild from peers
- `--wait`: Block until upgrade + reboot completes
- A/B boot scheme: Talos writes to the inactive boot slot and switches; automatic rollback if the new image fails to boot

**Gate resources with `count`**: `ovh_dedicated_server_reinstall_task`, `talos_machine_bootstrap`, and `terraform_data.tailscale_device_cleanup` are created only when `upgrade_mode = "reinstall"`.

### Phase 3: Multi-Node Rolling Upgrades (#211)

When the project expands to multi-node, add a Python rolling-upgrade script (`scripts/rolling_upgrade.py`) that:
1. Upgrades worker nodes in parallel (workloads reschedule)
2. Upgrades control plane nodes sequentially with etcd health checks between each
3. Talos's built-in etcd quorum protection prevents upgrading a CP node if it would break quorum

This phase is deferred until multi-node is actually implemented.

### When to Use Each Path

| Scenario | `upgrade_mode` | Mechanism |
|----------|---------------|-----------|
| First deploy (no existing node) | `"reinstall"` | OVH BYOI + bootstrap |
| Talos version bump | `"upgrade"` (default) | `talosctl upgrade --stage --preserve` |
| Extension add/remove | `"upgrade"` (default) | New schematic → `talosctl upgrade` |
| Inline manifest change (Renovate) | Either | `talos_machine_configuration_apply` (live, no reboot) |
| Config change (network, host entries) | Either | `talos_machine_configuration_apply` (live, no reboot) |
| Firewall rule change | `"upgrade"` + reboot | `talos_machine_configuration_apply` stages, manual reboot |
| Disaster recovery (bricked node) | `"reinstall"` | OVH BYOI + bootstrap |

## Consequences

### Positive

- Renovate dependency bumps no longer trigger reinstalls — config-only changes are applied live
- Version upgrades preserve etcd, ZFS pools, and Tailscale identity — minutes of downtime instead of 15-30
- Automatic rollback on failed upgrades via Talos A/B boot scheme
- `tofu apply` remains the single command for both paths — the `upgrade_mode` variable controls behavior
- Multi-node ready: the architecture scales to rolling upgrades without redesign

### Negative

- Two code paths (reinstall vs upgrade) increase complexity — more `count` conditionals, more resources
- `talosctl upgrade` via `local-exec` is not as clean as a native Terraform resource would be
- The operator must explicitly set `upgrade_mode = "reinstall"` for first deploy and DR — wrong default could fail
- State drift risk: if `talosctl upgrade` succeeds but Terraform crashes before recording it, manual state reconciliation is needed

### Risks

- `talosctl upgrade --stage` adds a second reboot to the upgrade cycle (~4-5 min total downtime on single-node vs ~2-3 min without `--stage`). Mandatory for ZFS safety.
- Inline manifest reconciliation in Talos is **additive-only** — removed resources are not deleted. Cleanup requires manual intervention or a separate mechanism.
- If the Talos provider adds a native upgrade resource in the future, the `local-exec` approach will need migration. This is a good problem to have.

## References

- [ADR-0012: Single-Node Destructive Upgrades](0012-single-node-destructive-upgrades.md) — the approach this ADR evolves
- [Talos Upgrading Guide](https://docs.siderolabs.com/talos/v1.6/configure-your-talos-cluster/lifecycle-management/upgrading-talos)
- [Editing Machine Configuration](https://docs.siderolabs.com/talos/v1.8/configure-your-talos-cluster/system-configuration/editing-machine-configuration)
- [KubePrism](https://docs.siderolabs.com/kubernetes-guides/advanced-guides/kubeprism) — localhost API proxy
- [ZFS upgrade issue #8800](https://github.com/siderolabs/talos/issues/8800) — unmount failure during upgrade
- [Missing Terraform upgrade resource #140](https://github.com/siderolabs/terraform-provider-talos/issues/140) — 91 thumbs up, open since Dec 2023
- [Image Factory](https://docs.siderolabs.com/talos/v1.9/learn-more/image-factory) — custom images with extensions
- [talos_machine_configuration_apply](https://registry.terraform.io/providers/siderolabs/talos/latest/docs/resources/machine_configuration_apply) — Terraform resource docs
- Phase 1 (live config apply): #209
- Phase 2 (in-place upgrade): #210
- Phase 3 (multi-node rolling): #211
- Reinstall trigger fix: #205
- ts.net DNS resolution: #157
