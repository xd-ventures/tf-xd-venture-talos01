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
                  ┌────────────┴───────────────┐
                  │                            │
             [Cloudflare]                  [Blocked]
             (Planned)                     (Firewall)
                  │                            │
                  ▼                            ▼
┌──────────────────────────────────────────────────────────────┐
│                    OVH Dedicated Server                       │
│  ┌─────────────────────────────────────────────────────────┐  │
│  │                   Talos Linux (GRUB Boot)               │  │
│  │                                                         │  │
│  │  ┌─────────────────┐  ┌───────────────────────────────┐ │  │
│  │  │   Tailscale     │  │          Cilium CNI           │ │  │
│  │  │   Extension     │  │   • eBPF dataplane            │ │  │
│  │  │   (100.x.x.x)   │  │   • Hubble observability      │ │  │
│  │  └─────────────────┘  │   • Gateway API               │ │  │
│  │                       └───────────────────────────────┘ │  │
│  │                                                         │  │
│  │  ┌────────────────────────────────────────────────────┐ │  │
│  │  │           Kubernetes Control Plane                 │ │  │
│  │  │   • API Server (6443) - Tailscale access only      │ │  │
│  │  │   • etcd - localhost only                          │ │  │
│  │  └────────────────────────────────────────────────────┘ │  │
│  │                                                         │  │
│  │  ┌────────────────────────────────────────────────────┐ │  │
│  │  │              ZFS Storage (mirror)                  │ │  │
│  │  │   NVMe 0 ◄─────────────────────► NVMe 1            │ │  │
│  │  │              /var/mnt/data                         │ │  │
│  │  └────────────────────────────────────────────────────┘ │  │
│  └─────────────────────────────────────────────────────────┘  │
└──────────────────────────────────────────────────────────────┘
                              │
                         [Tailscale]
                          (VPN Mesh)
                              │
       ┌──────────────────────┴──────────┐
       │                                 │
 [Admin Laptop]                     [Other Nodes]
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
# Configure backend (see "Remote State" section below)
cp backend.tfvars.example backend.tfvars
# Edit backend.tfvars with your bucket, region, and endpoint

tofu init -backend-config=backend.tfvars
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

## Deployment Demo

<details>
<summary><strong>Sample terminal output</strong> — what a successful deployment looks like</summary>

```console
$ tofu apply
  # ...plan output omitted...

  Plan: 13 to add, 0 to change, 0 to destroy.

  Changes to Outputs:
  + cluster_endpoint       = "https://talos-cluster.example-tailnet.ts.net:6443"
  + server_ip              = (known after apply)
  + tailscale_hostname     = "talos-cluster.example-tailnet.ts.net"
  + zfs_pool_info          = { status = "ENABLED", pool_name = "tank", topology = "mirror" }

  Do you want to perform these actions?
    OpenTofu will perform the actions described above.
    Only 'yes' will be accepted to approve.

    Enter a value: yes

  ovh_dedicated_server.talos01: Refreshing...
  talos_machine_secrets.this: Creating...
  talos_image_factory_schematic.this: Creating...
  tailscale_tailnet_key.talos[0]: Creating...
  talos_image_factory_schematic.this: Creation complete after 2s [id=ce4c98...]
  tailscale_tailnet_key.talos[0]: Creation complete after 1s
  ovh_dedicated_server_reinstall_task.talos: Creating...
  ovh_dedicated_server_reinstall_task.talos: Still creating... [5m0s elapsed]
  ovh_dedicated_server_reinstall_task.talos: Still creating... [10m0s elapsed]
  ovh_dedicated_server_reinstall_task.talos: Creation complete after 12m34s
  talos_machine_bootstrap.this: Creating...
  talos_machine_bootstrap.this: Still creating... [1m0s elapsed]
  talos_machine_bootstrap.this: Creation complete after 1m42s
  talos_cluster_kubeconfig.this: Creating...
  talos_cluster_kubeconfig.this: Creation complete after 3s

  Apply complete! Resources: 13 added, 0 changed, 0 destroyed.

  Outputs:

  cluster_endpoint       = "https://talos-cluster.example-tailnet.ts.net:6443"
  cluster_health_status  = "skipped (Tailscale enabled - verify manually)"
  firewall_enabled       = false
  firewall_warning       = "WARNING: Firewall is DISABLED — enable with: enable_firewall = true"
  server_ip              = "203.0.113.42"
  tailscale_enabled      = true
  tailscale_hostname     = "talos-cluster.example-tailnet.ts.net"
```

```console
$ tofu output -raw kubeconfig > kubeconfig && chmod 600 kubeconfig
$ export KUBECONFIG=$PWD/kubeconfig

$ kubectl get nodes -o wide
NAME           STATUS   ROLES           AGE   VERSION   INTERNAL-IP   OS-IMAGE
talos-cluster  Ready    control-plane   2m    v1.32.0   100.64.1.42   Talos (v1.9.2)

$ kubectl get pods -n kube-system
NAME                                       READY   STATUS      RESTARTS   AGE
cilium-operator-6f4d8b7c95-xk2mp          1/1     Running     0          90s
cilium-rn7kq                               1/1     Running     0          90s
coredns-5c5d6b8b7f-abcde                  1/1     Running     0          90s
hubble-relay-7f9d8c6b5d-fg2h1             1/1     Running     0          60s
kube-apiserver-talos-cluster               1/1     Running     0          2m
kube-controller-manager-talos-cluster      1/1     Running     0          2m
kube-scheduler-talos-cluster               1/1     Running     0          2m
zfs-pool-setup-abc12                       0/1     Completed   0          60s

$ kubectl logs -n kube-system job/zfs-pool-setup
=== ZFS Pool Setup ===
Pool: tank | Mount: /var/mnt/data
Creating partition 3 on /dev/nvme0n1...
Creating partition 1 on /dev/nvme1n1...
Creating ZFS pool 'tank' with mirror: /dev/nvme0n1p3 /dev/nvme1n1p1
=== ZFS Pool Created ===
  pool: tank
 state: ONLINE
config:

	NAME           STATE     READ WRITE CKSUM
	tank           ONLINE       0     0     0
	  mirror-0     ONLINE       0     0     0
	    nvme0n1p3  ONLINE       0     0     0
	    nvme1n1p1  ONLINE       0     0     0

errors: No known data errors
```

> **Note**: IPs and hostnames are sanitized. Actual deployment time is ~15 minutes, dominated by the OVH server reinstall.

</details>

## Post-Installation: ZFS Setup

ZFS pool creation is **automated** when `zfs_pool_enabled = true`. An inline manifest Job runs during bootstrap to partition the disks and create the mirror pool. No manual intervention is needed.

```hcl
# In terraform.tfvars:
zfs_pool_enabled = true
zfs_pool_disks = [
  { device = "/dev/nvme0n1", partition = 3 },  # Remaining space on OS disk
  { device = "/dev/nvme1n1", partition = 1 },  # First partition on data disk
]
```

Verify the pool after deployment:

```bash
kubectl logs -n kube-system job/zfs-pool-setup
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

> [!WARNING]
> The firewall is **disabled by default** to allow bootstrapping. While disabled, the Talos API (port 50000) and Kubernetes API (port 6443) are exposed on the public internet. Enable the firewall as soon as Tailscale connectivity is verified.

Enable the firewall after verifying Tailscale connectivity:

```bash
# Verify Tailscale works first
tofu output firewall_verification_commands
# Run each command to verify

# Then enable firewall
# Set enable_firewall = true in terraform.tfvars
tofu apply
```

## Remote State

The S3 backend is active by default. Environment-specific values (bucket, region, endpoint) are supplied via a `-backend-config` file so nothing sensitive is committed to the repository.

Any S3-compatible object storage works (OVH, AWS, MinIO, etc.). This project uses OVH Object Storage to keep all infrastructure within a single provider.

### Setup

```bash
# 1. Copy and fill in backend config
cp backend.tfvars.example backend.tfvars
# Edit: set bucket name, region, and endpoint for your provider

# 2. Set credentials via environment variables
export AWS_ACCESS_KEY_ID="<your-access-key>"
export AWS_SECRET_ACCESS_KEY="<your-secret-key>"

# 3. Initialize with backend
tofu init -backend-config=backend.tfvars
```

See [ADR-0006](docs/adr/0006-remote-state-backend.md) for the decision rationale and [ADR-0010](docs/adr/0010-terraform-state-migration-to-ovh-object-storage.md) for the full migration guide.

### Contributors

Contributors don't need backend credentials. Use `-backend=false` to skip remote state:

```bash
tofu init -backend=false    # works without any credentials
tofu validate               # validate HCL syntax
tofu fmt -check             # check formatting
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

Contributions are welcome! See [CONTRIBUTING.md](CONTRIBUTING.md) for setup instructions, workflow, and guidelines.

For AI agents, see [AGENTS.md](AGENTS.md) for detailed workflow instructions.

## References

- [Talos Documentation](https://www.talos.dev/v1.12/)
- [Cilium Documentation](https://docs.cilium.io/)
- [OVH BYOI Guide](https://help.ovhcloud.com/csm/en-dedicated-servers-bringyourownimage)
- [Tailscale Documentation](https://tailscale.com/kb/)
