# ADR-0012: Single-Node Deployment with Destructive Upgrade Path

> **Note**: The destructive upgrade approach documented here is superseded by
> [ADR-0013: Upgrade Lifecycle Architecture](0013-upgrade-lifecycle-architecture.md),
> which introduces non-destructive upgrade paths. The single-node deployment
> decision remains valid. See #209, #210, #211 for implementation.

## Status
Accepted (upgrade path superseded by ADR-0013)

## Date
2026-02-10

## Context
This project deploys a Talos Kubernetes cluster on a single OVH dedicated server. The physical constraint is one bare metal machine; the operational constraint is a single operator (hobby project).

OpenTofu manages the full server lifecycle including OS installation. Version upgrades are performed by updating `talos_version` and running `tofu apply`, which triggers an OVH BYOI reinstall. This reinstall wipes the disk and redeploys from scratch.

Talos Linux supports non-destructive in-place upgrades via `talosctl upgrade`, but this operates outside of OpenTofu's lifecycle management.

### Considered Options

#### Option 1: Single-node with reinstall-based upgrades (Selected)
- OpenTofu is the single source of truth for machine state
- `tofu apply` converges the server to the declared configuration
- Full cluster downtime during upgrades (15-30 minutes)
- All data on disk is wiped (etcd, ZFS pools, local PVs)

#### Option 2: Multi-node HA from day one
- Requires 3+ control plane nodes for etcd quorum
- Triples infrastructure cost for a non-production use case
- Significant operational complexity: rolling upgrades, inter-node networking, API server load balancing
- **Rejected**: Cost and complexity not justified by availability requirements

#### Option 3: Single-node with `talosctl upgrade` wired into OpenTofu
- Preserves etcd state and data partitions across upgrades
- Creates state drift: OpenTofu thinks the old version is deployed while the node runs the new one
- Requires reconciliation logic or lifecycle workarounds
- **Rejected for now**: Adds complexity without solving the fundamental single-node availability constraint

## Decision
Deploy to a single node with reinstall-based upgrades. Accept downtime during upgrades and data loss on reinstall as trade-offs for operational simplicity and cost efficiency.

### Why Single-Node Is Appropriate
- **Cost**: One server vs. three. The workloads do not justify tripling infrastructure cost.
- **Operational simplicity**: A single operator can manage one node reliably. Multi-node bare metal Kubernetes (etcd quorum, inter-node networking, rolling upgrades) demands significantly more operational effort.
- **Compensating controls**: ArgoCD GitOps allows workload recovery via sync after reinstall. Talos immutability means a fresh install with the same config produces an identical node. ZFS mirror protects against single-disk failure (the most common hardware failure mode).
- **Honest assessment**: The workloads do not have SLA commitments. Downtime is inconvenient, not costly.

## Consequences

### Positive
- OpenTofu remains the single source of truth — no state drift
- Simple mental model: change config → apply → server converges
- Lower cost (one server, not three)
- Sufficient for development, learning, and small-team production without uptime SLAs

### Negative
- Zero fault tolerance: any node failure is a total cluster outage
- Every upgrade is a full outage (~15-30 minutes)
- Persistent data on ZFS pools does not survive the reinstall path — external backups required
- No online maintenance (cannot drain the only node)
- Monitoring stack runs on the node it monitors (observability bootstrapping problem)

### Risks
- If the node suffers hardware failure, recovery depends on OVH's hardware replacement SLA (hours to days)
- etcd runs with quorum of 1 — no redundancy for cluster state

## Upgrade Paths

### Current: Destructive Reinstall via OpenTofu
```bash
# Change version in terraform.tfvars
talos_version = "v1.13.0"

# Apply triggers full reinstall
tofu apply
# ~15-30 minutes: reinstall + bootstrap + ArgoCD sync
```

**Use when**: Changing Talos extensions, changing the image schematic, initial deployment, disaster recovery, or when no persistent data needs to be preserved.

**Data impact**: Wipes everything — etcd, ZFS pools, local PVs. Workloads redeploy via ArgoCD.

### Alternative: In-Place Upgrade via talosctl
```bash
# Get the installer image URL from outputs
tofu output talos_installer_image
# Example: factory.talos.dev/installer/<schematic>:v1.13.0

# Perform in-place upgrade (preserves etcd and data partitions)
talosctl upgrade --image factory.talos.dev/installer/<schematic>:v1.13.0

# Update tfvars to match (prevents drift on next apply)
# WARNING: Changing talos_version in tfvars WILL trigger a reinstall on next tofu apply
# Use `tofu plan` to verify before applying
```

**Use when**: Routine Talos patch releases (e.g., v1.12.0 → v1.12.1), when preserving etcd state and ZFS pools is important, or when minimizing downtime matters (reboot-only: ~2-3 minutes vs. full reinstall: ~15-30 minutes).

**Data impact**: Preserves etcd data, ZFS pools, and local PVs. Only the OS partition is updated.

**Caveat**: After `talosctl upgrade`, OpenTofu state is out of sync with the running version. Update `talos_version` carefully — a `tofu apply` will attempt reinstall unless the trigger is managed.

## Evolution Path: Multi-Node

When to reconsider single-node:
- Customer-facing workloads with uptime commitments
- Stateful workloads where data loss is unacceptable
- Team growth beyond a single operator
- Cost of downtime exceeds cost of additional servers

What would need to change for multi-node:
- **etcd**: Open ports 2379-2380 between control plane nodes (currently localhost-only in `firewall.tf`)
- **API server**: Add a load balancer or Talos VIP for the Kubernetes API endpoint
- **Cilium**: Configure VXLAN/Geneve tunnel mode for cross-node pod networking
- **OpenTofu**: Use `for_each` on server resources, per-node reinstall triggers (rolling, never simultaneous)
- **Tailscale**: Each node needs its own Tailscale identity and auth key
- **Machine configs**: Separate `talos_machine_configuration` for control plane vs. worker nodes

## References
- [Talos Single Node Clusters](https://www.talos.dev/v1.12/introduction/single-node/)
- [Talos Upgrading](https://www.talos.dev/v1.12/talos-guides/upgrading-talos/)
- [ADR-0004: Storage Strategy](0004-storage-strategy.md) — ZFS mirror design
- [ADR-0001: Platform Selection](0001-platform-selection.md) — OVH BYOI mechanics
