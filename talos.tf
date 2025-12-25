# Talos OS Configuration Resources

# Generate cluster secrets including PKI
resource "talos_machine_secrets" "this" {}

# Create image factory schematic with extensions and kernel args
resource "talos_image_factory_schematic" "this" {
  schematic = yamlencode({
    customization = {
      extraKernelArgs = [
        "talos.platform=nocloud"
      ]
      systemExtensions = {
        officialExtensions = concat(
          [
            "siderolabs/amd-ucode",
            "siderolabs/mdadm"
          ],
          var.talos_extensions
        )
      }
    }
    bootloader = "sd-boot"
  })
}

# Get Talos OS image factory URLs with metal platform
data "talos_image_factory_urls" "this" {
  talos_version = var.talos_version
  schematic_id  = talos_image_factory_schematic.this.id
  architecture  = var.architecture
  platform      = "metal"
}

# Generate machine configuration for control plane node
data "talos_machine_configuration" "controlplane" {
  cluster_name     = var.cluster_name
  machine_type     = "controlplane"
  cluster_endpoint = var.cluster_endpoint
  machine_secrets  = talos_machine_secrets.this.machine_secrets
  talos_version    = var.talos_version
}

