# Talos Kubernetes Cluster on OVH Bare Metal

Infrastructure-as-Code for deploying a production-ready Talos Kubernetes cluster on OVH dedicated servers.

## Features

- **Immutable OS**: Talos Linux - secure, minimal, API-managed Kubernetes OS
- **Modern Networking**: Cilium CNI with eBPF, Hubble observability, and Gateway API
- **Zero-Trust Access**: Tailscale for secure API access (no public IP exposure)
- **Data Redundancy**: ZFS mirror for persistent storage across NVMe drives
- **GitOps Ready**: ArgoCD integration for application deployment
- **Full Automation**: Single `tofu apply` for complete cluster provisioning

## Architecture Overview

```
                              INTERNET
                                  │
                  ┌───────────────┴───────────────┐
                  │                               │
             [Cloudflare]                    [Blocked]
             (Tunnel Only)                   (Firewall)
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

### 1. Configure Credentials

```bash
# OVH API (get from https://api.ovh.com/createToken)
export OVH_ENDPOINT="ovh-eu"
export OVH_APPLICATION_KEY="your-app-key"
export OVH_APPLICATION_SECRET="your-app-secret"
export OVH_CONSUMER_KEY="your-consumer-key"

# Tailscale OAuth (create at https://login.tailscale.com/admin/settings/oauth)
# Required scope: auth_keys — see ADR-0008 for setup details
export TAILSCALE_OAUTH_CLIENT_ID="your-client-id"
export TAILSCALE_OAUTH_CLIENT_SECRET="tskey-client-xxx"
```

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

After the cluster is running, set up ZFS for data storage:

```bash
# SSH to node via Tailscale (use talosctl for commands)
TSIP=$(dig +short <hostname>.ts.net)
talosctl --endpoints $TSIP --nodes $TSIP shell

# Create ZFS partitions (adjust device names as needed)
sgdisk -n 1:0:0 -t 1:BF01 /dev/nvme1n1
sgdisk -n 3:0:0 -t 3:BF01 /dev/nvme0n1

# Create mirror pool
zpool create -m /var/mnt/data tank mirror /dev/nvme0n1p3 /dev/nvme1n1p1
```

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
| Public Services | Cloudflare Tunnel | 443 |
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
