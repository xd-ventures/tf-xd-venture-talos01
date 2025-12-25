# Talos OS Configuration Resources
#
# CRITICAL FIXES APPLIED:
# 1. Changed platform from "metal" to "nocloud" - this is the ROOT CAUSE of "failed to determine platform"
# 2. Removed sd-boot bootloader - OVH BYOI works better with GRUB (default)
# 3. Removed extraKernelArgs for talos.platform - not needed when using correct platform image
# 4. Fixed image URL construction for correct format

# Generate cluster secrets including PKI
resource "talos_machine_secrets" "this" {}

# Create image factory schematic with extensions
# NOTE: We don't need extraKernelArgs for platform when using the correct platform image
resource "talos_image_factory_schematic" "this" {
  schematic = yamlencode({
    customization = {
      # Only include kernel args that are actually needed beyond the default
      # The platform is determined by the image type (nocloud), not kernel args
      extraKernelArgs = var.extra_kernel_args
      systemExtensions = {
        officialExtensions = concat(
          [
            "siderolabs/amd-ucode",  # AMD CPU microcode updates
            # "siderolabs/mdadm"     # Uncomment if you need software RAID
          ],
          var.talos_extensions
        )
      }
    }
    # REMOVED: bootloader = "sd-boot"
    # Using default GRUB bootloader for better OVH BYOI compatibility
  })
}

# Get Talos OS image factory URLs
# CRITICAL: platform MUST be "nocloud" for OVH config drive to work
data "talos_image_factory_urls" "this" {
  talos_version = var.talos_version
  schematic_id  = talos_image_factory_schematic.this.id
  architecture  = var.architecture
  platform      = "nocloud"  # FIXED: was "metal" - this caused "failed to determine platform"
}

# Generate machine configuration for control plane node
data "talos_machine_configuration" "controlplane" {
  cluster_name     = var.cluster_name
  machine_type     = "controlplane"
  cluster_endpoint = var.cluster_endpoint
  machine_secrets  = talos_machine_secrets.this.machine_secrets
  talos_version    = var.talos_version
}

# Output the raw disk image URL for debugging
output "debug_disk_image_url" {
  description = "Raw disk image URL from image factory (for debugging)"
  value       = data.talos_image_factory_urls.this.urls.disk_image
}
