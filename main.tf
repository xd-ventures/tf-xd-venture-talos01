# OVH Bare Metal Server Configuration
#
# Deploys Talos OS on an OVH dedicated server using BYOI (Bring Your Own Image).
# Uses openstack platform image with GRUB bootloader for OVH compatibility.
# Supports both qcow2 and raw image formats.

resource "ovh_dedicated_server" "talos01" {
  ovh_subsidiary = var.ovh_subsidiary
  monitoring     = var.monitoring_enabled
  state          = var.server_state

  # Optional: uncomment to set custom display name
  # display_name   = var.cluster_name

  lifecycle {
    # Ignore display_name changes - requires additional OVH API permissions
    ignore_changes = [display_name]
  }
}

# Local values for image URL construction
locals {
  # The disk_image URL from the data source will be something like:
  # https://factory.talos.dev/image/SCHEMATIC_ID/v1.12.0/openstack-amd64.raw.xz

  # IMPORTANT: Talos Image Factory provides multiple image formats at predictable URLs
  # The provider's data source only returns the .raw.xz URL, but other formats are available:
  # - .raw.xz (compressed raw, returned by data source)
  # - .qcow2 (uncompressed qcow2, available but not in data source)
  # - .iso (ISO format, available but not in data source)
  # The URL pattern is consistent: replace the extension to get other formats

  # Raw image URL (compressed .raw.xz format)
  # OVH can decompress .xz automatically, but uncompressed formats are preferred for BYOI
  image_url_raw = data.talos_image_factory_urls.this.urls.disk_image

  # QCOW2 image URL (uncompressed .qcow2 format) - VERIFIED TO WORK
  # Talos Image Factory serves qcow2 format at predictable URLs by replacing .raw.xz with .qcow2
  # This has been verified: the qcow2 URL exists and returns HTTP 200 with valid image data
  # Pattern: openstack-amd64.raw.xz -> openstack-amd64.qcow2
  image_url_qcow2 = replace(
    replace(
      data.talos_image_factory_urls.this.urls.disk_image,
      ".raw.xz", ".qcow2" # Replace compressed raw (.raw.xz) with uncompressed qcow2
    ),
    ".raw.zst", ".qcow2" # Handle .zst compression format (.raw.zst -> .qcow2)
  )

  # Select image format based on use_raw_image variable
  # Default is qcow2 (false) as it's been verified to work well with OVH BYOI
  image_url  = var.use_raw_image ? local.image_url_raw : local.image_url_qcow2
  image_type = var.use_raw_image ? "raw" : "qcow2"

  # EFI bootloader path for Talos with GRUB (default bootloader)
  # For GRUB-based Talos images:
  efi_bootloader_path_grub = "\\EFI\\BOOT\\BOOTX64.EFI"

  # For sd-boot (unified kernel image) - NOT recommended for OVH BYOI:
  # efi_bootloader_path_sdboot = "\\EFI\\Linux\\Talos-${var.talos_version}.efi"

}

# Trigger reinstall when image URL or core cluster config changes
# This is needed because replace_triggered_by only accepts resource references
# Using terraform_data (built-in) instead of null_resource to avoid extra provider dependency
#
# IMPORTANT: We trigger on STABLE components only, NOT on volatile values like Tailscale auth key.
# The Tailscale key expires hourly but is only needed once during initial setup (TS_AUTH_ONCE=true).
# Changes to the key should NOT trigger cluster reinstall.
resource "terraform_data" "reinstall_trigger" {
  triggers_replace = [
    # Image configuration
    local.image_url,
    local.image_type,
    # Cluster configuration (stable)
    var.cluster_name,
    var.talos_version,
    local.actual_cluster_endpoint,
    # Extensions (stable)
    sha256(jsonencode(var.talos_extensions)),
    # CertSANs config (stable - depends only on ts.net hostname, not auth key)
    sha256(local.certsans_config_patch),
    # Tailscale config structure (stable - hostname and args, NOT the volatile auth key)
    var.tailscale_hostname,
    var.tailscale_tailnet,
    sha256(jsonencode(var.tailscale_extra_args)),
    # Firewall toggle and CIDRs — firewall rules are baked into the config drive,
    # so changing any of these requires a reinstall to update the config drive content
    var.enable_firewall,
    var.pod_network_cidr,
    var.service_network_cidr,
    var.tailscale_ipv4_cidr,
    var.tailscale_ipv6_cidr,
    # Config patches baked into the config drive — changes require reinstall
    # (inline manifests: Cilium install, ZFS pool setup, etc.)
    sha256(local.cluster_config_patch),
    sha256(local.zfs_config_patch),
    sha256(local.ephemeral_volume_config_patch),
  ]
}

# Talos OS Installation via OVH v2 API
#
# Uses terraform_data + local-exec instead of ovh_dedicated_server_reinstall_task
# because the OVH provider v2.11.0 uses the v1 API endpoint which returns HTTP 500.
# The v2 /dedicated/server/{sn}/reinstall endpoint works correctly.
# See: https://github.com/xd-ventures/tf-xd-venture-talos01/issues/130
resource "terraform_data" "reinstall" {
  depends_on = [terraform_data.tailscale_device_cleanup]

  # Store inputs so they're visible in state and available for triggers
  input = {
    service_name = ovh_dedicated_server.talos01.service_name
    hostname     = var.cluster_name
    image_url    = local.image_url
    image_type   = local.image_type
    efi_path     = local.efi_bootloader_path_grub
    instance_id  = "${var.cluster_name}-${terraform_data.reinstall_trigger.id}"
  }

  provisioner "local-exec" {
    command = "python3 ${path.module}/scripts/ovh_reinstall.py"
    environment = {
      OVH_REINSTALL_SERVICE_NAME = ovh_dedicated_server.talos01.service_name
      OVH_REINSTALL_HOSTNAME     = var.cluster_name
      OVH_REINSTALL_IMAGE_URL    = local.image_url
      OVH_REINSTALL_IMAGE_TYPE   = local.image_type
      OVH_REINSTALL_EFI_PATH     = local.efi_bootloader_path_grub
      # Base64-encoded: OVH base64-decodes before writing to the config drive ISO.
      # This avoids OVH's cleartext escape processing (\n → newline, \t → tab, etc.)
      # which corrupted YAML when templates contained literal escape sequences.
      # See: docs/rca-2026-02-config-drive-yaml-parse.md
      OVH_REINSTALL_USER_DATA = base64encode(data.talos_machine_configuration.controlplane.machine_configuration)
      # instance-id must change on every reinstall to force OVH to regenerate the
      # config drive. A static instance-id causes OVH to reuse the old config drive.
      OVH_REINSTALL_INSTANCE_ID = "${var.cluster_name}-${terraform_data.reinstall_trigger.id}"
    }
  }

  lifecycle {
    # Trigger reinstall when stable config changes
    replace_triggered_by = [
      terraform_data.reinstall_trigger,
    ]

    # Validate config drive content before reinstall — a broken config baked into the
    # config drive makes the server unreachable (no shell, no recovery without rescue mode).
    precondition {
      condition     = !local.tailscale_enabled || local.tailscale_authkey != ""
      error_message = "Tailscale is enabled but auth key is empty. The key may be consumed or expired. Taint tailscale_tailnet_key.talos to generate a fresh one."
    }

    precondition {
      condition     = local.image_url != ""
      error_message = "Image URL is empty. Check talos_version and the image factory schematic."
    }
  }
}
