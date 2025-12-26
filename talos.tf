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
# CRITICAL: Explicitly set platform kernel arg to ensure nocloud platform detection
resource "talos_image_factory_schematic" "this" {
  schematic = yamlencode({
    customization = {
      # TESTING: Try openstack platform kernel arg since OVH creates OpenStack format config drive
      # If openstack platform doesn't work, we'll revert to nocloud and use SMBIOS method
      extraKernelArgs = concat(
        ["talos.platform=openstack"],  # TESTING: OVH creates OpenStack format, try OpenStack platform
        var.extra_kernel_args
      )
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
# TESTING: Try "openstack" platform since OVH creates OpenStack format config drive (config-2 label, openstack/latest/user_data)
# OVH creates OpenStack format: config-2 label with openstack/latest/user_data structure
# Talos nocloud expects: cidata/CIDATA label with user-data in root
# If openstack platform doesn't work, we'll need to use SMBIOS method or embed config in image
data "talos_image_factory_urls" "this" {
  talos_version = var.talos_version
  schematic_id  = talos_image_factory_schematic.this.id
  architecture  = var.architecture
  platform      = "openstack"  # TESTING: OVH creates OpenStack format config drive, so try OpenStack platform
}

# Local values for endpoint/node extraction and cluster endpoint resolution
locals {
  # Replace <server-ip> placeholder with actual server IP from OVH resource
  # This allows using placeholder in tfvars and auto-resolving to actual IP
  actual_cluster_endpoint = replace(
    var.cluster_endpoint,
    "<server-ip>",
    try(ovh_dedicated_server.talos01.ip, "127.0.0.1")
  )
  
  # Extract IP address from actual cluster endpoint URL
  # Format: https://IP:6443 -> IP
  cluster_ip = replace(
    replace(local.actual_cluster_endpoint, "https://", ""),
    ":6443", ""
  )
  
  # Use explicit endpoints/nodes if provided, otherwise use cluster IP
  talos_endpoints = length(var.talos_endpoints) > 0 ? var.talos_endpoints : [local.cluster_ip]
  talos_nodes     = length(var.talos_nodes) > 0 ? var.talos_nodes : [local.cluster_ip]
}

# Generate machine configuration for control plane node
data "talos_machine_configuration" "controlplane" {
  cluster_name     = var.cluster_name
  machine_type     = "controlplane"
  cluster_endpoint = local.actual_cluster_endpoint
  machine_secrets  = talos_machine_secrets.this.machine_secrets
  talos_version    = var.talos_version
}

# Generate talosconfig for talosctl
data "talos_client_configuration" "this" {
  cluster_name         = var.cluster_name
  client_configuration = talos_machine_secrets.this.client_configuration
  endpoints            = local.talos_endpoints
  nodes                = local.talos_nodes
}

# Wait for Talos API to be ready before bootstrapping
data "talos_cluster_health" "this" {
  depends_on = [ovh_dedicated_server_reinstall_task.talos]

  client_configuration = talos_machine_secrets.this.client_configuration
  endpoints            = local.talos_endpoints
  control_plane_nodes  = local.talos_nodes
}

# Bootstrap the Talos cluster
# This initializes etcd and prepares the cluster for Kubernetes
resource "talos_machine_bootstrap" "this" {
  depends_on = [
    ovh_dedicated_server_reinstall_task.talos,
    data.talos_cluster_health.this,  # Wait for API to be ready
  ]

  client_configuration = talos_machine_secrets.this.client_configuration
  node                 = local.cluster_ip
  endpoint             = local.cluster_ip
}

# Output the raw disk image URL for debugging
output "debug_disk_image_url" {
  description = "Raw disk image URL from image factory (for debugging)"
  value       = data.talos_image_factory_urls.this.urls.disk_image
}
