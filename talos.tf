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
          # Conditionally include Tailscale extension when hostname and tailnet are configured
          var.tailscale_hostname != "" && var.tailscale_tailnet != "" ? ["siderolabs/tailscale"] : [],
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
  # Tailscale configuration
  # Use hostname and tailnet to determine if Tailscale is configured (avoids sensitivity from authkey)
  tailscale_enabled = var.tailscale_hostname != "" && var.tailscale_tailnet != ""
  tailscale_ts_net_hostname = (
    local.tailscale_enabled
    ? "${var.tailscale_hostname}.${var.tailscale_tailnet}.ts.net"
    : ""
  )

  # Replace <server-ip> placeholder with actual server IP from OVH resource
  # This allows using placeholder in tfvars and auto-resolving to actual IP
  # CRITICAL: No fallback to localhost - fail explicitly if IP is unavailable to prevent
  # baking 127.0.0.1 into the cluster configuration which would make it unreachable
  public_cluster_endpoint = replace(
    var.cluster_endpoint,
    "<server-ip>",
    ovh_dedicated_server.talos01.ip
  )

  # Use ts.net hostname as endpoint if Tailscale is fully configured, otherwise use public IP
  actual_cluster_endpoint = (
    local.tailscale_ts_net_hostname != ""
    ? "https://${local.tailscale_ts_net_hostname}:6443"
    : local.public_cluster_endpoint
  )
  
  # Extract IP address from public cluster endpoint URL (always use public IP for bootstrap)
  # Format: https://IP:6443 -> IP
  cluster_ip = replace(
    replace(local.public_cluster_endpoint, "https://", ""),
    ":6443", ""
  )
  
  # Use explicit endpoints/nodes if provided, otherwise use cluster IP
  # For initial bootstrap, always use public IP (Tailscale not yet available)
  talos_endpoints = length(var.talos_endpoints) > 0 ? var.talos_endpoints : [local.cluster_ip]
  talos_nodes     = length(var.talos_nodes) > 0 ? var.talos_nodes : [local.cluster_ip]

  # Tailscale extension service configuration patch
  tailscale_config_patch = local.tailscale_enabled ? yamlencode({
    apiVersion = "v1alpha1"
    kind       = "ExtensionServiceConfig"
    name       = "tailscale"
    environment = concat(
      [
        "TS_AUTHKEY=${var.tailscale_authkey}",
        "TS_AUTH_ONCE=true",  # Auth key used only once, subsequent restarts use stored state
      ],
      var.tailscale_hostname != "" ? ["TS_HOSTNAME=${var.tailscale_hostname}"] : [],
      [for arg in var.tailscale_extra_args : arg]
    )
  }) : ""

  # NOTE: Talos does not support inline firewall rules in machine configuration.
  # To restrict API access to Tailscale only, use one of these approaches:
  # 1. OVH's network firewall (block ports 50000, 6443 externally)
  # 2. Tailscale ACLs to control which devices can access the cluster
  # 3. Only share the ts.net hostname (not the public IP) with authorized users
  # The cluster endpoint is set to ts.net hostname, so configs will use Tailscale by default.

  # CertSANs configuration for ts.net hostname
  certsans_config_patch = local.tailscale_ts_net_hostname != "" ? yamlencode({
    machine = {
      certSANs = [local.tailscale_ts_net_hostname]
    }
    cluster = {
      apiServer = {
        certSANs = [local.tailscale_ts_net_hostname]
      }
    }
  }) : ""

  # Combined config patches for machine configuration
  config_patches = compact([
    local.tailscale_config_patch,
    local.certsans_config_patch,
  ])
}

# Generate machine configuration for control plane node
data "talos_machine_configuration" "controlplane" {
  cluster_name     = var.cluster_name
  machine_type     = "controlplane"
  cluster_endpoint = local.actual_cluster_endpoint
  machine_secrets  = talos_machine_secrets.this.machine_secrets
  talos_version    = var.talos_version

  # Apply config patches for Tailscale, firewall, and certSANs
  config_patches = local.config_patches
}

# Generate talosconfig for talosctl
data "talos_client_configuration" "this" {
  cluster_name         = var.cluster_name
  client_configuration = talos_machine_secrets.this.client_configuration
  endpoints            = local.talos_endpoints
  nodes                = local.talos_nodes
}

# Bootstrap the Talos cluster
# This initializes etcd and prepares the cluster for Kubernetes
# NOTE: We removed the talos_cluster_health dependency because it creates a chicken-and-egg problem:
# - The health check waits for etcd to be healthy
# - But etcd can't be healthy until bootstrap runs
# - The bootstrap resource has its own internal logic to wait for the Talos API to be ready
resource "talos_machine_bootstrap" "this" {
  depends_on = [
    ovh_dedicated_server_reinstall_task.talos,
  ]

  client_configuration = talos_machine_secrets.this.client_configuration
  node                 = local.cluster_ip
  endpoint             = local.cluster_ip

  # Force bootstrap to re-run when the server is reinstalled
  lifecycle {
    replace_triggered_by = [
      null_resource.reinstall_trigger,
    ]
  }
}

# Verify cluster health AFTER bootstrap completes
# This ensures the cluster is fully operational before Terraform finishes
data "talos_cluster_health" "this" {
  depends_on = [talos_machine_bootstrap.this]

  client_configuration   = talos_machine_secrets.this.client_configuration
  endpoints              = local.talos_endpoints
  control_plane_nodes    = local.talos_nodes
  skip_kubernetes_checks = true  # Only check Talos services, not full Kubernetes stack
}

# Extract kubeconfig for kubectl access
resource "talos_cluster_kubeconfig" "this" {
  depends_on = [talos_machine_bootstrap.this]

  client_configuration = talos_machine_secrets.this.client_configuration
  node                 = local.cluster_ip
  endpoint             = local.cluster_ip
}

# Output the raw disk image URL for debugging
output "debug_disk_image_url" {
  description = "Raw disk image URL from image factory (for debugging)"
  value       = data.talos_image_factory_urls.this.urls.disk_image
}
