# Architecture Overview

This document provides a high-level overview of the Talos Kubernetes cluster architecture on OVH bare metal.

## System Architecture

```
                                    INTERNET
                                        │
                        ┌───────────────┴───────────────┐
                        │                               │
                   [Cloudflare]                    [Blocked]
                   (Tunnel Only)                   (Firewall)
                        │                               │
                        ▼                               ▼
┌──────────────────────────────────────────────────────────────────────┐
│                    OVH Dedicated Server                               │
│  ┌────────────────────────────────────────────────────────────────┐  │
│  │                     Talos Linux (GRUB Boot)                    │  │
│  │                                                                │  │
│  │  ┌────────────────────┐  ┌─────────────────────────────────┐  │  │
│  │  │   Tailscale        │  │         Cilium CNI              │  │  │
│  │  │   Extension        │  │   • eBPF dataplane              │  │  │
│  │  │   (100.x.x.x)      │  │   • Hubble observability        │  │  │
│  │  │                    │  │   • Gateway API                 │  │  │
│  │  └────────────────────┘  └─────────────────────────────────┘  │  │
│  │                                                                │  │
│  │  ┌────────────────────────────────────────────────────────┐   │  │
│  │  │              Kubernetes Control Plane                   │   │  │
│  │  │   • API Server (6443) - Tailscale access only          │   │  │
│  │  │   • etcd - localhost only                              │   │  │
│  │  │   • Controller Manager, Scheduler                      │   │  │
│  │  └────────────────────────────────────────────────────────┘   │  │
│  │                                                                │  │
│  │  ┌────────────────────────────────────────────────────────┐   │  │
│  │  │                      Workloads                          │   │  │
│  │  │   • Grafana (playground)                               │   │  │
│  │  │   • Temporal (workflow engine)                         │   │  │
│  │  │   • Other internal tools                               │   │  │
│  │  └────────────────────────────────────────────────────────┘   │  │
│  └────────────────────────────────────────────────────────────────┘  │
│                                                                       │
│  ┌────────────────────────────────────────────────────────────────┐  │
│  │                     Storage Layer                              │  │
│  │                                                                │  │
│  │  NVMe 0 (960GB)              NVMe 1 (960GB)                   │  │
│  │  ┌──────────────────┐        ┌──────────────────┐             │  │
│  │  │ Talos System     │        │                  │             │  │
│  │  │ (~20GB)          │        │                  │             │  │
│  │  ├──────────────────┤        │                  │             │  │
│  │  │ ZFS Partition    │◄──────►│ ZFS Partition    │  MIRROR    │  │
│  │  │ (~940GB)         │        │ (~940GB)         │             │  │
│  │  └──────────────────┘        └──────────────────┘             │  │
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
| Public Access | Cloudflare Tunnel | Secure exposure |
| Firewall | Talos NetworkRuleConfig | Block public IP |

### Storage Layer

| Component | Technology | Purpose |
|-----------|------------|---------|
| System Disk | NVMe (Talos-managed) | OS, etcd, ephemeral |
| Data Storage | ZFS Mirror | Persistent volumes |
| PV Provisioner | local-path-provisioner | Kubernetes PVs |
| Backup | Velero | Disaster recovery |

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
| Network (Public) | TLS (Cloudflare) | TLS 1.3 |
| Disk (STATE) | LUKS2 | Talos encryption |
| Disk (Data) | ZFS encryption (optional) | At-rest encryption |

## Extension Points

### Adding Nodes
1. Provision additional OVH servers
2. Join to existing Tailscale network
3. Apply worker node Talos config
4. ZFS automatically handles replication

### Adding Storage
1. Create additional ZFS datasets
2. Mount via machine config
3. Configure local-path-provisioner paths

### Adding Public Services
1. Deploy workload with Gateway API
2. Configure Cloudflare Tunnel route
3. No firewall changes needed

## Failure Modes

| Failure | Impact | Recovery |
|---------|--------|----------|
| System disk failure | Cluster down | Reinstall via Terraform (~15 min) |
| Data disk failure | ZFS handles it | Replace disk, resilver |
| Both disks fail | Full cluster loss | Restore from Velero backup |
| Tailscale outage | No admin access | Emergency: disable firewall via iKVM |
| Network partition | Workloads affected | Automatic recovery on reconnect |

## Related Documents

- [ADR Index](adr/README.md) - Architecture decisions
- [Testing Strategy](TESTING_STRATEGY.md) - Validation approach
- [OVH BYOI Guide](OVH_BYOI_GUIDE.md) - Installation specifics
