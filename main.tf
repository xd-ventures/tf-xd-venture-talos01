# OVH Bare Metal Server Configuration
#
# FIXES APPLIED:
# 1. Corrected image_url to use nocloud platform image
# 2. Fixed EFI bootloader path for GRUB (not sd-boot)
# 3. Added image_type handling for raw images (OVH prefers raw for BYOI)

resource "ovh_dedicated_server" "talos01" {
  ovh_subsidiary = var.ovh_subsidiary
  monitoring     = var.monitoring_enabled
  state          = var.server_state
  
  # Optional: uncomment to set custom display name
  # display_name   = var.cluster_name
}

# Local values for image URL construction
locals {
  # The disk_image URL from the data source will be something like:
  # https://factory.talos.dev/image/SCHEMATIC_ID/v1.12.0/nocloud-amd64.raw.xz
  
  # For OVH BYOI, we can use either:
  # 1. Raw image (.raw.xz) - preferred, written directly to disk
  # 2. qcow2 image (.qcow2) - also supported
  
  # Option 1: Use raw image directly (recommended)
  # OVH can decompress .xz automatically
  image_url_raw = data.talos_image_factory_urls.this.urls.disk_image
  
  # Option 2: Use qcow2 format (uncompressed)
  # Talos Image Factory provides uncompressed qcow2 format
  # OVH BYOI requires uncompressed formats (no .xz or .zst compression)
  # Pattern: nocloud-amd64.raw.xz or openstack-amd64.raw.xz -> .qcow2
  # Strategy: Replace the entire suffix (.raw.xz or .raw.zst) with .qcow2
  image_url_qcow2 = replace(
    replace(
      data.talos_image_factory_urls.this.urls.disk_image,
      ".raw.xz", ".qcow2"  # Replace compressed raw (.raw.xz) with uncompressed qcow2
    ),
    ".raw.zst", ".qcow2"  # Handle .zst compression format (.raw.zst -> .qcow2)
  )
  
  # OVH BYOI requires image_type to be "qcow2" to match the deployed image format
  # Always use qcow2 format for OVH BYOI compatibility
  image_url = local.image_url_qcow2
  image_type = "qcow2"
  
  # EFI bootloader path for Talos with GRUB (default bootloader)
  # For GRUB-based Talos images:
  efi_bootloader_path_grub = "\\EFI\\BOOT\\BOOTX64.EFI"
  
  # For sd-boot (unified kernel image) - NOT recommended for OVH BYOI:
  # efi_bootloader_path_sdboot = "\\EFI\\Linux\\Talos-${var.talos_version}.efi"
  
  # Hash of image URL and machine config to trigger reinstall when they change
  # This ensures that changing the platform, image, or config triggers a new reinstallation
  reinstall_trigger = sha256("${local.image_url_qcow2}${data.talos_machine_configuration.controlplane.machine_configuration}")
}

# Null resource to trigger reinstall when image URL or machine config changes
# This is needed because replace_triggered_by only accepts resource references
resource "null_resource" "reinstall_trigger" {
  triggers = {
    image_url = local.image_url_qcow2
    machine_config_hash = sha256(data.talos_machine_configuration.controlplane.machine_configuration)
  }
}

# Talos OS Installation Task
# This will trigger a server reinstallation with Talos OS using BYOI
resource "ovh_dedicated_server_reinstall_task" "talos" {
  service_name = ovh_dedicated_server.talos01.service_name
  os           = "byoi_64"
  
  customizations {
    hostname = var.cluster_name
    
    # Image URL - using platform-specific image (nocloud or openstack)
    image_url = local.image_url
    
    # Image type - must match the actual image format
    image_type = local.image_type
    
    # EFI bootloader path - for GRUB-based boot
    # OVH requires backslashes for the path
    efi_bootloader_path = local.efi_bootloader_path_grub
    
    # Config drive user data - Talos expects raw YAML machine config
    # OVH will base64 encode this automatically, so we pass it as plain text
    # Double-encoding would prevent Talos from reading it
    config_drive_user_data = data.talos_machine_configuration.controlplane.machine_configuration
    
    # Config drive metadata - minimal metadata to ensure config drive structure
    # This helps ensure the config drive is properly mounted and recognized
    config_drive_metadata = {
      instance-id    = var.cluster_name
      local-hostname = var.cluster_name
    }
  }
  
  # CRITICAL: Force replacement when image URL or machine config changes
  # This ensures that changing the platform, image, or machine config triggers a new reinstallation
  # We use null_resource.reinstall_trigger which changes when dependencies change
  lifecycle {
    replace_triggered_by = [
      null_resource.reinstall_trigger,  # Replace when image URL or machine config changes
    ]
  }
}

# Output for debugging
output "installation_image_url" {
  description = "The image URL being used for installation"
  value       = local.image_url
}

output "installation_image_type" {
  description = "The image type being used"
  value       = local.image_type
}

output "efi_bootloader_path" {
  description = "The EFI bootloader path being used"
  value       = local.efi_bootloader_path_grub
}
