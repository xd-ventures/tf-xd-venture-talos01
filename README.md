# Talos Kubernetes Cluster on OVH Bare Metal

[![License](https://img.shields.io/badge/License-Apache_2.0-blue.svg)](LICENSE)
[![PR Validation](https://github.com/xd-ventures/tf-xd-venture-talos01/actions/workflows/pr-validation.yml/badge.svg)](https://github.com/xd-ventures/tf-xd-venture-talos01/actions/workflows/pr-validation.yml)
[![OpenTofu](https://img.shields.io/badge/OpenTofu-%3E%3D1.6.0-blue.svg)](https://opentofu.org/)

Infrastructure-as-Code for deploying a production-ready Talos Kubernetes cluster on OVH dedicated servers.

## Features

- **Immutable OS**: Talos Linux - secure, minimal, API-managed Kubernetes OS
- **Modern Networking**: Cilium CNI with eBPF, Hubble observability, and Gateway API
- **Zero-Trust Access**: Tailscale for secure API access (no public IP exposure)
- **Data Redundancy**: ZFS mirror for persistent storage across NVMe drives
- **GitOps Ready**: ArgoCD integration for application deployment
- **Automated Bootstrapping**: Single `tofu apply` provisions the cluster; ZFS storage requires a one-time post-install step

> **Scope**: This project deploys a single-node cluster on one dedicated server. Version upgrades trigger a full reinstall with planned downtime (~15-30 minutes). Designed for development, homelab, and small-team production workloads where maintenance windows are acceptable. See [ADR-0012](docs/adr/0012-single-node-destructive-upgrades.md) for the multi-node upgrade path.

## Architecture Overview

```
                              INTERNET
                                  │
                  ┌───────────────┴───────────────┐
                  │                               │
             [Cloudflare]                    [Blocked]
             (Planned)                       (Firewall)
                  │                               │
                  ▼                               ▼
┌──────────────────────────────────────────────────────────────┐
│                    OVH Dedicated Server                       │
│  ┌────────────────────────────────────────────────────────┐  │
│  │                   Talos Linux (GRUB Boot)               │  │
│  │                                                          │  │
│  │  ┌─────────────────┐  ┌───────────────────────────────┐ │  │
│  │  │   Tailscale     │  │          Cilium CNI           │ │  │
│  │  │   Extension     │  │   • eBPF dataplane            │ │  │
│  │  │   (100.x.x.x)   │  │   • Hubble observability      │ │  │
│  │  └─────────────────┘  │   • Gateway API               │ │  │
│  │                        └───────────────────────────────┘ │  │
│  │                                                          │  │
│  │  ┌────────────────────────────────────────────────────┐ │  │
│  │  │           Kubernetes Control Plane                  │ │  │
│  │  │   • API Server (6443) - Tailscale access only      │ │  │
│  │  │   • etcd - localhost only                          │ │  │
│  │  └────────────────────────────────────────────────────┘ │  │
│  │                                                          │  │
│  │  ┌────────────────────────────────────────────────────┐ │  │
│  │  │              ZFS Storage (mirror)                   │ │  │
│  │  │   NVMe 0 ◄─────────────────────► NVMe 1            │ │  │
│  │  │              /var/mnt/data                          │ │  │
│  │  └────────────────────────────────────────────────────┘ │  │
│  └────────────────────────────────────────────────────────┘  │
└──────────────────────────────────────────────────────────────┘
                  │
             [Tailscale]
             (VPN Mesh)
                  │
       ┌──────────┴──────────┐
       │                     │
 [Admin Laptop]       [Other Nodes]
```

## Quick Start

### Prerequisites

- [OpenTofu](https://opentofu.org/) or Terraform >= 1.6.0
- OVH account with API credentials
- Tailscale account with OAuth client (see [ADR-0008](docs/adr/0008-tailscale-authentication-strategy.md))
- Existing OVH dedicated server

> **Cost & Hardware**: Talos requires a minimum of 2 CPU cores, 2 GiB RAM, and 10 GiB disk for a control plane node — modest hardware is sufficient for playground or homelab use. [OVH Eco servers](https://eco.ovhcloud.com/en-ie/) offer budget-friendly dedicated servers starting from ~10 EUR/month (Kimsufi, limited availability) or ~30 EUR/month (So You Start). [Tailscale](https://tailscale.com/pricing/) is free for personal use.

### 1. Configure Credentials

#### OVH API

Create API credentials at [api.ovh.com/createToken](https://api.ovh.com/createToken):

```bash
export OVH_ENDPOINT="ovh-eu"
export OVH_APPLICATION_KEY="your-app-key"
export OVH_APPLICATION_SECRET="your-app-secret"
export OVH_CONSUMER_KEY="your-consumer-key"
```

#### Tailscale OAuth

This project uses a [Tailscale OAuth client](https://tailscale.com/kb/1215/oauth-clients) for automated device registration (see [ADR-0008](docs/adr/0008-tailscale-authentication-strategy.md) for rationale).

**Setup steps:**

1. **Configure ACL tags** — add [tag ownership](https://tailscale.com/kb/1068/acl-tags) to your tailnet policy file so the OAuth client can assign tags to devices:
   ```json
   {
     "tagOwners": {
       "tag:k8s-cluster": ["tag:terraform"],
       "tag:terraform": []
     }
   }
   ```
2. **Create an OAuth client** — in the Tailscale admin console under [Settings > OAuth clients](https://login.tailscale.com/admin/settings/oauth), create a credential with scopes:
   - `auth_keys` (required) — generate pre-auth keys for device registration
   - `devices:read` (recommended) — auto-discover the node's Tailscale IP for firewall rules
3. **Export credentials:**
   ```bash
   export TAILSCALE_OAUTH_CLIENT_ID="your-client-id"
   export TAILSCALE_OAUTH_CLIENT_SECRET="tskey-client-xxx"
   ```

> [!NOTE]
> Without `devices:read`, automatic Tailscale IP discovery is disabled and you must
> manage the node's Tailscale IP manually. See [ADR-0008](docs/adr/0008-tailscale-authentication-strategy.md) for full scope details.

See the [Tailscale Terraform provider docs](https://tailscale.com/kb/1210/terraform-provider) for more on provider authentication.

### 2. Configure Variables

```bash
cp terraform.tfvars.example terraform.tfvars
# Edit terraform.tfvars with your values
```

Key variables:
```hcl
ovh_subsidiary     = "FR"                    # OVH region
cluster_name       = "talos-cluster"         # Cluster name
talos_version      = "v1.12.0"               # Talos version
tailscale_hostname = "talos-cluster"         # Tailscale hostname
tailscale_tailnet  = "tail12345"             # Your tailnet name
```

### 3. Deploy

```bash
tofu init
tofu plan
tofu apply
```

### 4. Access the Cluster

```bash
# Save kubeconfig
tofu output -raw kubeconfig > kubeconfig
export KUBECONFIG=$PWD/kubeconfig

# Verify access (via Tailscale)
kubectl get nodes

# Save talosconfig for node management
tofu output -raw talosconfig > talosconfig
export TALOSCONFIG=$PWD/talosconfig
```

## Post-Installation: ZFS Setup

After the cluster is running, set up ZFS for data storage. The ZFS kernel module and `ext-zpool-importer` service are already installed via the [siderolabs/zfs extension](https://github.com/siderolabs/extensions/blob/main/storage/zfs/README.md) — you only need to create the pool once.

> **Note:** Talos Linux has no SSH or shell access. To run host-level commands, you need a privileged Kubernetes pod. See the [ZFS extension docs](https://github.com/siderolabs/extensions/blob/main/storage/zfs/README.md) for the full procedure. The example below uses a privileged pod to access the host namespace:

```bash
# Launch a privileged debug pod on the node
kubectl run zfs-setup --rm -it --restart=Never \
  --overrides='{"spec":{"hostPID":true,"hostNetwork":true,"containers":[{"name":"zfs-setup","image":"alpine","command":["nsenter","--target","1","--mount","--uts","--ipc","--net","--","sh"],"stdin":true,"tty":true,"securityContext":{"privileged":true}}]}}' \
  --image=alpine

# Inside the pod — create ZFS partitions (adjust device names as needed)
sgdisk -n 1:0:0 -t 1:BF01 /dev/nvme1n1
sgdisk -n 3:0:0 -t 3:BF01 /dev/nvme0n1

# Create mirror pool
zpool create -m /var/mnt/data tank mirror /dev/nvme0n1p3 /dev/nvme1n1p1
```

Once created, the pool is automatically imported on every boot by the `ext-zpool-importer` service. See [ADR-0004](docs/adr/0004-storage-strategy.md) for the full storage strategy.

## Directory Structure

```
.
├── main.tf                 # OVH server + reinstall task
├── talos.tf                # Talos configuration and bootstrap
├── tailscale.tf            # Tailscale provider and auth key
├── firewall.tf             # Network firewall rules
├── argocd.tf               # ArgoCD deployment (optional)
├── variables.tf            # Input variables
├── outputs.tf              # Output values
├── versions.tf             # Provider versions
├── backend.tf              # Remote state configuration
├── terraform.tfvars.example # Example configuration
├── templates/
│   └── cilium-install-job.yaml.tftpl  # Cilium CNI install manifest
├── docs/
│   ├── ARCHITECTURE.md     # Detailed architecture
│   ├── TESTING_STRATEGY.md # Validation procedures
│   ├── OVH_BYOI_GUIDE.md   # OVH installation specifics
│   └── adr/                # Architecture Decision Records
└── scripts/
    ├── ovh-server-status.sh  # Check server status
    ├── ovh-rescue-boot.sh    # Boot to rescue mode
    └── ovh-normal-boot.sh    # Restore normal boot
```

## Security Model

| Access Type | Method | Ports |
|------------|--------|-------|
| Admin (kubectl, talosctl) | Tailscale VPN | 6443, 50000 |
| Public Services | Cloudflare Tunnel (planned) | 443 |
| Public Internet | Blocked by firewall | - |

Enable the firewall after verifying Tailscale connectivity:

```bash
# Verify Tailscale works first
tofu output firewall_verification_commands
# Run each command to verify

# Then enable firewall
# Set enable_firewall = true in terraform.tfvars
tofu apply
```

## Remote State (Optional)

To use OVH Object Storage for remote state:

1. Create an Object Storage container in OVH
2. Generate S3 credentials
3. Configure backend:

```bash
cp backend.tfvars.example backend.tfvars
# Edit backend.tfvars with your credentials

# Uncomment backend block in backend.tf
tofu init -backend-config=backend.tfvars
```

## Upgrades

### Talos Version Upgrade

```bash
# Update talos_version in terraform.tfvars
talos_version = "v1.13.0"

# Apply - this triggers reinstall
tofu apply
```

### Add Extensions

```bash
# Add to talos_extensions list
talos_extensions = ["siderolabs/iscsi-tools"]

# Apply - triggers reinstall with new schematic
tofu apply
```

### Configuration Updates (no reinstall)

Use `talosctl apply-config` for runtime config changes that don't require reinstall.

## Troubleshooting

### Server Not Responding

```bash
# Check server status via OVH API
./scripts/ovh-server-status.sh

# Boot to rescue mode for debugging
./scripts/ovh-rescue-boot.sh
```

### Tailscale Connection Issues

```bash
# Verify node is in your tailnet
tailscale status

# Test direct connectivity
TSIP=$(dig +short <hostname>.ts.net)
tailscale ping $TSIP
```

### Cluster Health

```bash
# Check Talos services
talosctl --endpoints $TSIP service

# Check Kubernetes components
talosctl --endpoints $TSIP health
```

## Documentation

- [Architecture Overview](docs/ARCHITECTURE.md)
- [Testing Strategy](docs/TESTING_STRATEGY.md)
- [Architecture Decision Records](docs/adr/README.md)

## Contributing

Contributions are welcome! This project uses **GitHub Flow** with an issue-first approach:

1. **Open an issue first** for significant changes (new features, bugs, refactoring)
   - This allows discussion before implementation
   - Minor fixes (typos, small docs updates) can skip this step
2. Fork the repository
3. Create a feature branch from `main`, referencing the issue number (e.g., `feature/42-add-monitoring`)
4. Commit your changes with descriptive messages
5. Open a Pull Request that **references the issue** (use `Fixes #42` in the PR description)

Please note: This is a solo hobby project, so PR reviews may take some time. Your patience is appreciated!

For AI agents contributing to this codebase, see [AGENTS.md](AGENTS.md) for detailed workflow instructions.

## References

- [Talos Documentation](https://www.talos.dev/v1.12/)
- [Cilium Documentation](https://docs.cilium.io/)
- [OVH BYOI Guide](https://help.ovhcloud.com/csm/en-dedicated-servers-bringyourownimage)
- [Tailscale Documentation](https://tailscale.com/kb/)
