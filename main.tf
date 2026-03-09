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
  ]
}

# Talos OS Installation Task
# This will trigger a server reinstallation with Talos OS using BYOI
resource "ovh_dedicated_server_reinstall_task" "talos" {
  depends_on   = [terraform_data.tailscale_device_cleanup]
  service_name = ovh_dedicated_server.talos01.service_name
  os           = "byoi_64"

  customizations {
    hostname = var.cluster_name

    # Image URL - using openstack platform image for OVH BYOI
    image_url = local.image_url

    # Image type - must match the actual image format
    image_type = local.image_type

    # EFI bootloader path - for GRUB-based boot
    # OVH requires backslashes for the path
    efi_bootloader_path = local.efi_bootloader_path_grub

    # Config drive user data - Talos expects raw YAML machine config
    # Base64-encoded: OVH base64-decodes before writing to the config drive ISO.
    # This avoids OVH's cleartext escape processing (\n → newline, \t → tab, etc.)
    # which corrupted YAML when templates contained literal escape sequences.
    # See: docs/rca-2026-02-config-drive-yaml-parse.md
    config_drive_user_data = base64encode(data.talos_machine_configuration.controlplane.machine_configuration)

    # Config drive metadata - minimal metadata to ensure config drive structure
    # IMPORTANT: instance-id must change on every reinstall to force OVH to
    # regenerate the config drive. A static instance-id causes OVH to reuse
    # the old config drive even when config_drive_user_data has changed.
    config_drive_metadata = {
      instance-id    = "${var.cluster_name}-${terraform_data.reinstall_trigger.id}"
      local-hostname = var.cluster_name
    }
  }

  # CRITICAL: Force replacement when core config changes (via stable trigger)
  # We use terraform_data.reinstall_trigger which tracks only STABLE values
  # (excludes volatile Tailscale auth key to prevent unnecessary reinstalls)
  lifecycle {
    # Ignore changes to config_drive_user_data - it contains the volatile Tailscale auth key
    # which changes hourly. The key is only used once during initial setup (TS_AUTH_ONCE=true).
    # Reinstalls should only be triggered by our STABLE trigger, not by key rotation.
    ignore_changes = [
      customizations[0].config_drive_user_data,
    ]

    # Trigger reinstall when stable config changes
    replace_triggered_by = [
      terraform_data.reinstall_trigger,
    ]
  }
}
