# Talos OS on OVH Bare Metal - Fixed Configuration

## Root Cause Analysis

The **"failed to determine platform"** error and reboot loop was caused by a **platform mismatch** between what the image expects and what the data source was configured to fetch.

### Original Issue in `talos.tf`:

```hcl
# WRONG - This fetches metal-amd64.raw.zst image
data "talos_image_factory_urls" "this" {
  platform = "metal"  # <-- This was the problem!
}
```

The `metal` platform image requires the `talos.platform=metal` kernel argument to be explicitly passed, OR it tries to auto-detect the platform from hardware/hypervisor signatures. On OVH bare metal with BYOI, this auto-detection fails.

### The Fix:

```hcl
# CORRECT - This fetches nocloud-amd64.raw.xz image
data "talos_image_factory_urls" "this" {
  platform = "nocloud"  # Platform is baked into the image
}
```

The `nocloud` platform image has `talos.platform=nocloud` baked in and knows how to read configuration from cloud-init style config drives - which is exactly what OVH's `config_drive_user_data` provides!

## All Issues Fixed

| Issue | Original | Fixed |
|-------|----------|-------|
| Platform | `metal` | `nocloud` |
| Bootloader | `sd-boot` | GRUB (default) |
| EFI Path | `/EFI/Linux/Talos-v1.12.0.efi` | `\EFI\BOOT\BOOTX64.EFI` |
| Extra Kernel Args | `talos.platform=nocloud` (redundant) | Removed (baked into image) |
| Image URL | `.raw.zst` → `.qcow2` replace | Proper format handling |

## How Talos nocloud Platform Works

1. **Boot**: Server boots from the Talos nocloud image
2. **Platform Detection**: Talos sees `talos.platform=nocloud` and looks for config drive
3. **Config Drive**: OVH creates a config drive partition with your `config_drive_user_data`
4. **Configuration**: Talos reads machine config from the config drive as `user-data`
5. **Installation**: Talos installs itself to disk with your configuration

## Files Overview

```
.
├── main.tf           # OVH server + reinstall task with BYOI
├── talos.tf          # Talos schematic, image URLs, machine config
├── variables.tf      # Input variables
├── terraform.tfvars  # Your configuration values
├── versions.tf       # Provider versions
└── outputs.tf        # Outputs including debug info
```

## Usage

### 1. Update `terraform.tfvars`

```hcl
ovh_subsidiary   = "FR"                              # Your OVH region
talos_version    = "v1.12.0"                         # Talos version
cluster_name     = "talos-xd-venture"                # Cluster name
cluster_endpoint = "https://YOUR_SERVER_IP:6443"    # Replace with actual IP
install_disk     = "/dev/sda"                        # Or /dev/nvme0n1
```

### 2. Initialize and Plan

```bash
tofu init
tofu plan
```

### 3. Check the Image URL

Before applying, verify the image URL looks correct:

```bash
tofu plan -out=plan.tfplan
tofu show -json plan.tfplan | jq '.planned_values.outputs.talos_image_url.value'
```

Expected URL format:
```
https://factory.talos.dev/image/SCHEMATIC_ID/v1.12.0/nocloud-amd64.raw.xz
```

NOT:
```
https://factory.talos.dev/image/SCHEMATIC_ID/v1.12.0/metal-amd64.raw.zst
```

### 4. Apply

```bash
tofu apply
```

### 5. After Installation

Once the server reboots with Talos, use `talosctl` to interact:

```bash
# Get the talosconfig
tofu output -raw talosconfig > talosconfig

# Set up talosctl
export TALOSCONFIG=./talosconfig
talosctl config endpoint <server-ip>
talosctl config node <server-ip>

# Check status
talosctl health --wait-timeout 10m

# Bootstrap the cluster (only once!)
talosctl bootstrap

# Get kubeconfig
talosctl kubeconfig ./kubeconfig
```

## Troubleshooting

### Still seeing "failed to determine platform"?

1. **Verify the image URL** in Terraform output contains `nocloud-amd64`, not `metal-amd64`

2. **Check schematic** doesn't override platform:
   ```bash
   tofu state show talos_image_factory_schematic.this
   ```

3. **Try manual test** - download the image and verify:
   ```bash
   # Get the URL from terraform output
   URL=$(tofu output -raw talos_image_url)
   
   # This should return nocloud-amd64 in the filename
   echo $URL
   ```

### Can't reach the server after boot?

1. **Check OVH KVM/IPMI console** - Talos should show its dashboard
2. **Verify network config** - Talos nocloud will use DHCP by default
3. **Check cluster_endpoint** - make sure it matches the server's actual IP

### Image download fails?

The Image Factory URL format for nocloud is:
- Raw: `https://factory.talos.dev/image/{schematic_id}/{version}/nocloud-amd64.raw.xz`
- QCOW2: `https://factory.talos.dev/image/{schematic_id}/{version}/nocloud-amd64.qcow2`

If raw.xz doesn't work, try setting `use_raw_image = false` to use qcow2.

## Alternative: Using metal Platform with Explicit Config

If you really need to use the `metal` platform (for some reason), you'd need to:

1. Use `platform = "metal"` in the data source
2. Pass `talos.config=https://your-server.com/config.yaml` as kernel argument
3. Host the machine config on an accessible HTTP server

This is more complex and requires external config hosting, which is why `nocloud` is recommended for OVH BYOI.

## References

- [Talos nocloud Platform Documentation](https://www.talos.dev/v1.12/talos-guides/install/cloud-platforms/nocloud/)
- [Talos Image Factory](https://factory.talos.dev/)
- [OVH BYOI Documentation](https://help.ovhcloud.com/csm/en-dedicated-servers-bringyourownimage)
- [Terraform Talos Provider](https://registry.terraform.io/providers/siderolabs/talos/latest/docs)
