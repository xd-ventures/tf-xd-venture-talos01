# OVH BYOI Guide for Talos Linux

This guide covers the specifics of deploying Talos Linux on OVH dedicated servers using [Bring Your Own Image (BYOI)](https://help.ovhcloud.com/csm/en-dedicated-servers-bringyourownimage).

## How OVH BYOI Works

OVH BYOI allows installing a custom OS image on a dedicated server via the OVH API. The process:

1. You provide an image URL and metadata via the API (or Terraform)
2. OVH boots the server into a provisioning environment
3. The image is downloaded and written to the primary disk
4. A **config drive** partition is created with your user data
5. The server reboots into the installed OS

This project automates steps 1-5 via the `ovh_dedicated_server_reinstall_task` resource in `main.tf`.

## Image Format

Talos images are built via [Talos Image Factory](https://factory.talos.dev/) with a schematic that includes the required extensions (Tailscale, ZFS, etc.).

### Supported Formats

| Format | Extension | OVH Support | Notes |
|--------|-----------|-------------|-------|
| QCOW2 | `.qcow2` | Yes | **Default** — tested and reliable |
| Raw compressed | `.raw.xz` | Yes | OVH decompresses automatically |

The `use_raw_image` variable controls which format is used (default: `false` = QCOW2).

### Image URL Construction

The Talos provider returns a `.raw.xz` URL. For QCOW2, we replace the extension — Talos Image Factory serves both formats at predictable URLs:

```
# Raw:   https://factory.talos.dev/image/<schematic>/v1.12.0/openstack-amd64.raw.xz
# QCOW2: https://factory.talos.dev/image/<schematic>/v1.12.0/openstack-amd64.qcow2
```

## Platform and Config Drive

OVH BYOI creates an **OpenStack-format config drive** alongside the installed OS:

- Volume label: `config-2`
- User data path: `openstack/latest/user_data`
- Format: raw YAML (not base64 encoded)

Talos must be configured with `platform=openstack` to read this config drive. Using `platform=nocloud` or `platform=metal` will **not** work — Talos will fail to find its machine configuration at boot.

See [ADR-0001](../adr/0001-platform-selection.md) for the platform decision and [ADR-0011](../adr/0011-ovh-config-drive-format.md) for the detailed config drive investigation.

## Bootloader

OVH BYOI uses UEFI boot. This project uses **GRUB** (not UKI/systemd-boot) because OVH has known issues with EFI variable persistence between reinstalls ([siderolabs/talos#12300](https://github.com/siderolabs/talos/issues/12300)).

The EFI bootloader path must be set explicitly:

```hcl
efi_bootloader_path = "\\EFI\\BOOT\\BOOTX64.EFI"
```

See [ADR-0002](../adr/0002-bootloader-selection.md) for details.

## OVH API Configuration

### Required API Credentials

Generate at [https://api.ovh.com/createToken](https://api.ovh.com/createToken):

```bash
export OVH_ENDPOINT="ovh-eu"
export OVH_APPLICATION_KEY="your-app-key"
export OVH_APPLICATION_SECRET="your-app-secret"
export OVH_CONSUMER_KEY="your-consumer-key"
```

### Required API Permissions

The OVH API token needs access to:

| Method | Path | Purpose |
|--------|------|---------|
| GET | `/dedicated/server/*` | Read server info |
| PUT | `/dedicated/server/*` | Update server config |
| POST | `/dedicated/server/*/reinstall` | Trigger BYOI reinstall |
| GET | `/dedicated/server/*/task/*` | Monitor reinstall progress |

## Reinstall Process

When `tofu apply` triggers a reinstall (image change, cluster config change, etc.):

1. OVH API receives the reinstall request with image URL and user data
2. Server reboots into OVH provisioning environment (~2-3 minutes)
3. Image is downloaded and written to disk (~5-10 minutes depending on image size)
4. Config drive is created with the Talos machine configuration
5. Server reboots into Talos (~1-2 minutes)
6. Talos reads config from the `config-2` drive and bootstraps Kubernetes

Total time: approximately 10-15 minutes from `tofu apply` to a running cluster.

### What Triggers a Reinstall

The `terraform_data.reinstall_trigger` resource tracks **stable** configuration values. A reinstall is triggered when any of these change:

- Image URL or type
- Cluster name or Talos version
- Cluster endpoint
- Extensions list
- CertSANs configuration
- Tailscale hostname, tailnet, or extra args

The Tailscale auth key is explicitly **excluded** — it rotates hourly but is only needed once during initial setup (`TS_AUTH_ONCE=true`).

## Diagnostic Scripts

The `scripts/` directory contains OVH utility scripts for troubleshooting:

| Script | Purpose |
|--------|---------|
| [`ovh-server-status.sh`](../../scripts/ovh-server-status.sh) | Check server status via OVH API |
| [`ovh-rescue-boot.sh`](../../scripts/ovh-rescue-boot.sh) | Boot server into rescue mode |
| [`ovh-normal-boot.sh`](../../scripts/ovh-normal-boot.sh) | Restore normal boot mode |
| [`ovh-ipmi-access.sh`](../../scripts/ovh-ipmi-access.sh) | Access server via IPMI/iKVM |
| [`ovh-wait-task.sh`](../../scripts/ovh-wait-task.sh) | Wait for OVH API task completion |
| [`inspect-config-drive.sh`](../../scripts/inspect-config-drive.sh) | Inspect config drive format (rescue mode) |

### Rescue Mode

If the server is unreachable after a failed install:

```bash
# Boot into rescue mode
./scripts/ovh-rescue-boot.sh

# SSH into rescue (credentials provided by OVH via email)
ssh root@<server-ip>

# Inspect what happened
lsblk -f                           # Check disk layout
blkid | grep config                 # Find config drive
mount /dev/nvme0n1p5 /mnt && ls /mnt  # Check config drive contents
```

## Related Documentation

- [ADR-0001: Platform Selection](../adr/0001-platform-selection.md) — why `platform=openstack`
- [ADR-0002: Bootloader Selection](../adr/0002-bootloader-selection.md) — why GRUB over UKI
- [ADR-0011: OVH Config Drive Format](../adr/0011-ovh-config-drive-format.md) — config drive investigation
- [OVH BYOI Documentation](https://help.ovhcloud.com/csm/en-dedicated-servers-bringyourownimage) — official OVH docs
- [Talos Bare Metal Guide](https://www.talos.dev/v1.12/talos-guides/install/bare-metal-platforms/) — upstream Talos docs
