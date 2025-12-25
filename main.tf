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
  
  # Option 2: Try qcow2 format (fallback)
  # Replace .raw.xz with .qcow2 (Image Factory provides both formats)
  image_url_qcow2 = replace(
    replace(data.talos_image_factory_urls.this.urls.disk_image, ".raw.xz", ".qcow2"),
    ".raw.zst", ".qcow2"
  )
  
  # Choose which image type to use
  use_raw_image = var.use_raw_image
  
  # Final image URL based on selection
  image_url = local.use_raw_image ? local.image_url_raw : local.image_url_qcow2
  image_type = local.use_raw_image ? "raw" : "qcow2"
  
  # EFI bootloader path for Talos with GRUB (default bootloader)
  # For GRUB-based Talos images:
  efi_bootloader_path_grub = "\\EFI\\BOOT\\BOOTX64.EFI"
  
  # For sd-boot (unified kernel image) - NOT recommended for OVH BYOI:
  # efi_bootloader_path_sdboot = "\\EFI\\Linux\\Talos-${var.talos_version}.efi"
}

# Talos OS Installation Task
# This will trigger a server reinstallation with Talos OS using BYOI
resource "ovh_dedicated_server_reinstall_task" "talos" {
  # Uncomment if you want to prevent re-installation on every apply
  # lifecycle {
  #   ignore_changes = all
  # }
  
  service_name = ovh_dedicated_server.talos01.service_name
  os           = "byoi_64"
  
  customizations {
    hostname = var.cluster_name
    
    # Image URL - using nocloud platform image
    image_url = local.image_url
    
    # Image type - must match the actual image format
    image_type = local.image_type
    
    # EFI bootloader path - for GRUB-based boot
    # OVH requires backslashes for the path
    efi_bootloader_path = local.efi_bootloader_path_grub
    
    # Config drive user data - this is where Talos nocloud platform
    # expects to find its machine configuration (as "user-data")
    # The nocloud platform will read this from the config drive partition
    config_drive_user_data = base64encode(
      data.talos_machine_configuration.controlplane.machine_configuration
    )
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
