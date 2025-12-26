# Talos OS Configuration Resources
#
# CRITICAL FIXES APPLIED:
# 1. Changed platform from "metal" to "openstack" - OVH creates OpenStack format config drive (config-2 label, openstack/latest/user_data)
# 2. Removed sd-boot bootloader - OVH BYOI works better with GRUB (default)
# 3. Explicitly set talos.platform=openstack kernel arg to ensure platform detection
# 4. Fixed image URL construction for correct format

# Generate cluster secrets including PKI
resource "talos_machine_secrets" "this" {}

# Create image factory schematic with extensions
# CRITICAL: Explicitly set platform kernel arg to ensure openstack platform detection
resource "talos_image_factory_schematic" "this" {
  schematic = yamlencode({
    customization = {
      # Explicitly set openstack platform kernel arg since OVH creates OpenStack format config drive
      # OVH BYOI creates config drive with config-2 label and openstack/latest/user_data structure
      # Talos openstack platform supports this format
      extraKernelArgs = concat(
        ["talos.platform=openstack"],  # OVH creates OpenStack format, use OpenStack platform
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
# Use "openstack" platform since OVH creates OpenStack format config drive (config-2 label, openstack/latest/user_data)
# OVH BYOI creates config drive with:
#   - Volume label: config-2 (OpenStack format)
#   - File location: openstack/latest/user_data
# Talos openstack platform supports this format and reads the config from the correct location
data "talos_image_factory_urls" "this" {
  talos_version = var.talos_version
  schematic_id  = talos_image_factory_schematic.this.id
  architecture  = var.architecture
  platform      = "openstack"  # OVH creates OpenStack format config drive, use OpenStack platform
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
