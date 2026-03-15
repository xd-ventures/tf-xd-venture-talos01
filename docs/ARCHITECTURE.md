# Architecture Overview

This document provides a high-level overview of the Talos Kubernetes cluster architecture on OVH bare metal.

## System Architecture

```
                                    INTERNET
                                        │
                        ┌───────────────┴───────────────┐
                        │                               │
                   [Cloudflare]                    [Blocked]
                   (Planned)                       (Firewall)
                        │                               │
                        ▼                               ▼
┌──────────────────────────────────────────────────────────────────────┐
│                    OVH Dedicated Server                              │
│  ┌────────────────────────────────────────────────────────────────┐  │
│  │                     Talos Linux (GRUB Boot)                    │  │
│  │                                                                │  │
│  │  ┌────────────────────┐  ┌─────────────────────────────────┐   │  │
│  │  │   Tailscale        │  │         Cilium CNI              │   │  │
│  │  │   Extension        │  │   • eBPF dataplane              │   │  │
│  │  │   (100.x.x.x)      │  │   • Hubble observability        │   │  │
│  │  │                    │  │   • Gateway API                 │   │  │
│  │  └────────────────────┘  └─────────────────────────────────┘   │  │
│  │                                                                │  │
│  │  ┌────────────────────────────────────────────────────────┐    │  │
│  │  │              Kubernetes Control Plane                  │    │  │
│  │  │   • API Server (6443) - Tailscale access only          │    │  │
│  │  │   • etcd - localhost only                              │    │  │
│  │  │   • Controller Manager, Scheduler                      │    │  │
│  │  └────────────────────────────────────────────────────────┘    │  │
│  │                                                                │  │
│  │  ┌────────────────────────────────────────────────────────┐    │  │
│  │  │                      Workloads                         │    │  │
│  │  │   • Grafana (playground)                               │    │  │
│  │  │   • Temporal (workflow engine)                         │    │  │
│  │  │   • Other internal tools                               │    │  │
│  │  └────────────────────────────────────────────────────────┘    │  │
│  └────────────────────────────────────────────────────────────────┘  │
│                                                                      │
│  ┌────────────────────────────────────────────────────────────────┐  │
│  │                     Storage Layer                              │  │
│  │                                                                │  │
│  │  NVMe 0 (960GB)              NVMe 1 (960GB)                    │  │
│  │  ┌──────────────────┐        ┌──────────────────┐              │  │
│  │  │ Talos System     │        │                  │              │  │
│  │  │ (~20GB)          │        │                  │              │  │
│  │  ├──────────────────┤        │                  │              │  │
│  │  │ ZFS Partition    │◄──────►│ ZFS Partition    │  MIRROR      │  │
│  │  │ (~940GB)         │        │ (~940GB)         │              │  │
│  │  └──────────────────┘        └──────────────────┘              │  │
│  │           │                          │                         │  │
│  │           └──────────┬───────────────┘                         │  │
│  │                      ▼                                         │  │
│  │              ┌───────────────┐                                 │  │
│  │              │  ZFS Pool     │                                 │  │
│  │              │  "tank"       │                                 │  │
│  │              │  (mirror)     │                                 │  │
│  │              └───────┬───────┘                                 │  │
│  │                      ▼                                         │  │
│  │              /var/mnt/data                                     │  │
│  │              (local-path-provisioner)                          │  │
│  └────────────────────────────────────────────────────────────────┘  │
└──────────────────────────────────────────────────────────────────────┘
                        │
                   [Tailscale]
                   (VPN Mesh)
                        │
            ┌───────────┴───────────┐
            │                       │
     [Admin Laptop]          [Other Tailnet Nodes]
     • talosctl                • kubectl access
     • kubectl
```

## Component Summary

### Infrastructure Layer

| Component | Technology | Purpose |
|-----------|------------|---------|
| Server | OVH Dedicated (Bare Metal) | Physical compute |
| OS | Talos Linux | Immutable Kubernetes OS |
| Bootloader | GRUB | OVH BYOI compatibility |
| Platform | OpenStack | Config drive detection |

### Networking Layer

| Component | Technology | Purpose |
|-----------|------------|---------|
| CNI | Cilium | Container networking |
| Observability | Hubble | Network flow visibility |
| Ingress | Gateway API | HTTP/HTTPS routing |
| Admin Access | Tailscale | Zero-trust VPN |
| Public Access | Cloudflare Tunnel (planned) | Secure public exposure |
| Firewall | Talos NetworkRuleConfig | Block public IP |

### Storage Layer

| Component | Technology | Purpose |
|-----------|------------|---------|
| System Disk | NVMe (Talos-managed) | OS, etcd, ephemeral |
| Data Storage | ZFS Mirror | Persistent volumes |
| PV Provisioner | local-path-provisioner | Kubernetes PVs |
| Backup | Velero (planned) | Disaster recovery |

### Management Layer

| Component | Technology | Purpose |
|-----------|------------|---------|
| IaC | OpenTofu/Terraform | Infrastructure as Code |
| State Backend | OVH Object Storage | Remote state |
| GitOps | ArgoCD (planned) | Application deployment |
| Secrets | External (TBD) | Secret management |

## Security Model

### Access Control

```
┌─────────────────────────────────────────────────────────┐
│                    Access Zones                          │
├─────────────────────────────────────────────────────────┤
│                                                          │
│  BLOCKED (Public Internet)                               │
│  ├── Port 50000 (Talos API)         ❌ Blocked          │
│  ├── Port 6443 (Kubernetes API)     ❌ Blocked          │
│  ├── Port 10250 (Kubelet)           ❌ Blocked          │
│  └── Port 2379-2380 (etcd)          ❌ Blocked          │
│                                                          │
│  ALLOWED (Tailscale Network - 100.64.0.0/10)            │
│  ├── Port 50000 (Talos API)         ✅ Allowed          │
│  ├── Port 6443 (Kubernetes API)     ✅ Allowed          │
│  ├── Port 10250 (Kubelet)           ✅ Allowed          │
│  └── Port 4244 (Hubble)             ✅ Allowed          │
│                                                          │
│  ALLOWED (Pod Network - 10.244.0.0/16)                  │
│  └── Internal cluster communication  ✅ Allowed          │
│                                                          │
│  LOCALHOST ONLY                                          │
│  └── Port 2379-2380 (etcd)          ✅ Allowed          │
│                                                          │
└─────────────────────────────────────────────────────────┘
```

### Encryption

| Layer | Technology | Notes |
|-------|------------|-------|
| Network (Admin) | WireGuard (Tailscale) | End-to-end encrypted |
| Network (Public) | TLS (Cloudflare, planned) | TLS 1.3 |
| Disk (STATE) | LUKS2 | Talos encryption |
| Disk (Data) | ZFS encryption (optional) | At-rest encryption |

## Deployment Topology

This project deploys a **single control plane node** with `allowSchedulingOnControlPlanes = true`. This is a deliberate choice — see [ADR-0012](adr/0012-single-node-destructive-upgrades.md) for the full rationale.

### Upgrade Mechanics

Version upgrades (`talos_version` change) trigger a full OVH BYOI reinstall via `tofu apply`. This wipes the disk including etcd state and ZFS pools. Expected downtime: 15-30 minutes. Workloads redeploy automatically via ArgoCD.

For non-destructive upgrades that preserve data, use `talosctl upgrade` with the installer image from `tofu output talos_installer_image`. See ADR-0012 for detailed guidance on when to use each approach.

### Single-Node Trade-offs

| Aspect | Implication |
|--------|-------------|
| Availability | No fault tolerance — any node failure is a total cluster outage |
| Maintenance | Every upgrade or maintenance task requires cluster downtime |
| etcd | Quorum of 1 — no redundancy for cluster state |
| Data | ZFS pools do not survive reinstall — external backups required for persistent data |
| Monitoring | Observability stack runs on the node it monitors |

## Extension Points

### Adding Nodes
This requires significant infrastructure changes (see [ADR-0012](adr/0012-single-node-destructive-upgrades.md) for details):
1. Provision additional OVH servers (separate `ovh_dedicated_server` resources)
2. Open etcd ports (2379-2380) between control plane nodes
3. Add API server load balancer or Talos VIP
4. Configure Cilium tunnel mode for cross-node pod networking
5. Create separate machine configs for control plane vs. worker nodes
6. Each node needs its own Tailscale identity

### Adding Storage
1. Create additional ZFS datasets
2. Mount via machine config
3. Configure local-path-provisioner paths

## Talos Host Binary Reference

Talos Linux is an immutable, shell-less OS. Understanding what's available on the host is critical
for any Jobs that use `nsenter` or `hostPID`.

| Host Path | Binaries | Provided By |
|-----------|----------|-------------|
| `/sbin/` | LVM (lvcreate, lvchange, etc.), iptables/arptables, mkfs.* (ext4, xfs, vfat), cryptsetup, containerd, dmsetup | Talos base OS |
| `/usr/local/sbin/` | zpool, zfs, zdb, zed, zstream | `siderolabs/zfs` extension (overlayfs) |

**Not available on host**: `/bin/sh`, `/bin/bash`, `sfdisk`, `sgdisk`, `fdisk`, `partprobe`, `test`, `curl`, `wget`

### Implications for Privileged Jobs

- **nsenter works** for host binaries: `nsenter --mount=/proc/1/ns/mnt -- /usr/local/sbin/zpool`
- **nsenter fails** for commands not on the host (no shell, no partition tools)
- Use full paths: `nsenter ... -- /usr/local/sbin/zpool` (not just `zpool`)
- For missing tools: install them in the container image and run directly (privileged containers have `/dev/` access)

### Adding Public Services (planned)
1. Deploy workload with Gateway API
2. Configure Cloudflare Tunnel route
3. No firewall changes needed (Tailscale traffic already allowed)

## Failure Modes

| Failure | Impact | Recovery |
|---------|--------|----------|
| System disk failure | Cluster down | Reinstall via Terraform (~15 min) |
| Data disk failure | ZFS handles it | Replace disk, resilver |
| Both disks fail | Full cluster loss | Reinstall via Terraform; data recovery requires external backups (Velero planned but not yet implemented) |
| Tailscale outage | No admin access | Emergency: disable firewall via iKVM |
| Network partition | Workloads affected | Automatic recovery on reconnect |

## Related Documents

- [ADR Index](adr/README.md) - Architecture decisions
- [Testing Strategy](TESTING_STRATEGY.md) - Validation approach
- [OVH BYOI Guide](guides/OVH_BYOI_GUIDE.md) - Installation specifics
