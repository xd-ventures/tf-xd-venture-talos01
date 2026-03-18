# SPDX-License-Identifier: Apache-2.0
# Copyright Maciej Sawicki

# Talos OS Configuration Resources
#
# Configures Talos Linux for OVH bare metal with:
# - OpenStack platform (OVH creates OpenStack format config drives)
# - GRUB bootloader (default, best OVH BYOI compatibility)
# - Cilium CNI with eBPF dataplane
# - Tailscale for secure remote access

# Generate cluster secrets including PKI
resource "talos_machine_secrets" "this" {}

# Create image factory schematic with extensions
resource "talos_image_factory_schematic" "this" {
  schematic = yamlencode({
    customization = {
      # Extra kernel args (e.g. serial console); platform is set via data.talos_image_factory_urls
      extraKernelArgs = var.extra_kernel_args
      systemExtensions = {
        officialExtensions = concat(
          [
            "siderolabs/amd-ucode", # AMD CPU microcode updates
            "siderolabs/zfs",       # ZFS for data storage (mirrored NVMe drives)
          ],
          # Conditionally include Tailscale extension when hostname and tailnet are configured
          var.tailscale_hostname != "" && var.tailscale_tailnet != "" ? ["siderolabs/tailscale"] : [],
          var.talos_extensions
        )
      }
    }
    # Uses default GRUB bootloader (best compatibility with OVH BYOI)
  })
}

# Get Talos OS image factory URLs
# Platform "openstack" tells Talos to read config from the OVH config drive
# (config-2 label, openstack/latest/user_data)
data "talos_image_factory_urls" "this" {
  talos_version = var.talos_version
  schematic_id  = talos_image_factory_schematic.this.id
  architecture  = var.architecture
  platform      = "openstack" # OVH creates OpenStack format config drive, use OpenStack platform
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

  # Tailscale IP for Talos API operations (firewall apply, config apply, etc.)
  # Priority: data source lookup > manual override > public IP fallback
  # See ADR-0009 for design rationale
  tailscale_endpoint_ip = (
    length(data.tailscale_device.talos_node) > 0
    ? data.tailscale_device.talos_node[0].addresses[0] # Dynamic lookup (preferred)
    : coalesce(var.tailscale_ip, local.cluster_ip)     # Manual fallback
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

  # Use ts.net hostname when Tailscale is enabled for secure access.
  # On-node DNS resolution is handled by extraHostEntries mapping to 127.0.0.1.
  # KubePrism (enabled by default since Talos 1.6, port 7445) handles internal
  # API traffic via localhost. See extra_host_entries_config_patch below.
  actual_cluster_endpoint = (
    local.tailscale_enabled
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
  # These are used for talosctl config and health checks (not bootstrap)
  talos_endpoints = length(var.talos_endpoints) > 0 ? var.talos_endpoints : [local.cluster_ip]
  talos_nodes     = length(var.talos_nodes) > 0 ? var.talos_nodes : [local.cluster_ip]

  # Tailscale auth key — read directly from the key resource.
  # The key is consumed once on boot (TS_AUTH_ONCE=true) and expires after 1h.
  # On reinstall, replace_triggered_by on the key resource generates a fresh one.
  tailscale_authkey = local.tailscale_enabled ? tailscale_tailnet_key.talos[0].key : ""

  # Tailscale extension service configuration patch
  # NOTE: TS_AUTH_ONCE=true means the auth key is used only once during initial setup.
  # After that, Tailscale stores its state and won't need the key again.
  # For reinstalls, the Tailscale provider auto-generates a new key.
  tailscale_config_patch = local.tailscale_enabled ? yamlencode({
    apiVersion = "v1alpha1"
    kind       = "ExtensionServiceConfig"
    name       = "tailscale"
    environment = concat(
      [
        "TS_AUTHKEY=${local.tailscale_authkey}",
        "TS_AUTH_ONCE=true", # Auth key used only once, subsequent restarts use stored state
      ],
      var.tailscale_hostname != "" ? ["TS_HOSTNAME=${var.tailscale_hostname}"] : [],
      [for arg in var.tailscale_extra_args : arg]
    )
  }) : ""

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

  # Static host entry: map ts.net hostname to localhost for on-node DNS resolution.
  #
  # The Tailscale extension runs in userspace networking mode and does NOT configure
  # host DNS to use MagicDNS (100.100.100.100). The node's resolver (127.0.0.53)
  # cannot resolve ts.net hostnames, causing persistent DNS errors in components
  # that resolve the cluster endpoint URL directly (EndpointSlice controller, etc.).
  #
  # KubePrism (enabled by default since Talos 1.6, port 7445) handles most internal
  # API traffic via localhost, but some components still resolve the endpoint URL.
  # This host entry ensures they resolve to 127.0.0.1, which works because:
  # 1. On CP nodes: kube-apiserver listens on 127.0.0.1:6443
  # 2. Talos 1.6.3+ auto-injects 127.0.0.1 into API server cert SANs
  # 3. Multi-node ready: workers use KubePrism (7445) for all API traffic,
  #    so the host entry is only exercised on CP nodes where 6443 is local.
  #
  # See: https://github.com/siderolabs/talos/issues/10441
  # See: https://docs.siderolabs.com/kubernetes-guides/advanced-guides/kubeprism
  extra_host_entries_config_patch = local.tailscale_enabled ? yamlencode({
    machine = {
      network = {
        extraHostEntries = [
          {
            ip      = "127.0.0.1"
            aliases = [local.tailscale_ts_net_hostname]
          }
        ]
      }
    }
  }) : ""

  # ZFS kernel module configuration
  # Loads the ZFS module at boot for the ZFS extension
  zfs_config_patch = yamlencode({
    machine = {
      kernel = {
        modules = [
          { name = "zfs" }
        ]
      }
    }
  })

  # Limit EPHEMERAL partition to leave space for ZFS on the OS disk.
  # VolumeConfig is a separate Talos document (not machine/cluster config).
  # Only applied on fresh installs — cannot shrink an existing EPHEMERAL.
  # See: https://www.talos.dev/v1.9/reference/configuration/block/volumeconfig/
  ephemeral_volume_config_patch = var.zfs_pool_enabled ? yamlencode({
    apiVersion = "v1alpha1"
    kind       = "VolumeConfig"
    name       = "EPHEMERAL"
    provisioning = {
      diskSelector = {
        match = "system_disk"
      }
      maxSize = var.ephemeral_max_size
      grow    = false
    }
  }) : ""

  # Cilium installation manifest
  # Uses Cilium CLI job to install Cilium with native routing mode
  # See templates/cilium-install-job.yaml.tftpl for the full manifest
  cilium_install_manifest = templatefile("${path.module}/templates/cilium-install-job.yaml.tftpl", {
    cilium_cli_version = var.cilium_cli_version
    cilium_cli_digest  = var.cilium_cli_digest
  })

  # ZFS pool setup manifest (only when enabled)
  # Uses a privileged Job with nsenter to run host ZFS/sfdisk binaries
  # See templates/zfs-pool-job.yaml.tftpl for the full manifest
  zfs_pool_manifest = var.zfs_pool_enabled ? templatefile("${path.module}/templates/zfs-pool-job.yaml.tftpl", {
    pool_name     = var.zfs_pool_name
    mount_point   = var.zfs_pool_mount_point
    disk_args     = join(" ", [for d in var.zfs_pool_disks : "${d.device}:${d.partition}"])
    alpine_image  = var.alpine_image
    alpine_digest = var.alpine_digest
  }) : ""

  # Cluster-level config patch: CNI, inline manifests, and scheduling
  # NOTE: Talos uses JSON merge patch (RFC 7396) — arrays are replaced, not appended.
  # All inline manifests MUST be in a single config patch to avoid overwrites.
  cluster_config_patch = yamlencode({
    cluster = {
      # Disable default Flannel CNI (Cilium replaces it)
      network = {
        cni = {
          name = "none"
        }
      }
      # Inline manifests: Cilium CNI install + optional ZFS pool setup
      inlineManifests = concat(
        [{ name = "cilium-install", contents = local.cilium_install_manifest }],
        var.zfs_pool_enabled ? [{ name = "zfs-pool-setup", contents = local.zfs_pool_manifest }] : []
      )
      # Skip waiting for CNI during bootstrap (Cilium installs after API server)
      allowSchedulingOnControlPlanes = true
    }
  })

  # Combined config patches for machine configuration
  # Firewall patches are included here (not applied post-boot) so the firewall
  # is active from first boot — BEFORE Talos API starts listening.
  config_patches = compact(concat(
    [
      local.tailscale_config_patch,
      local.certsans_config_patch,
      local.extra_host_entries_config_patch,
      local.zfs_config_patch,
      local.cluster_config_patch,
      local.ephemeral_volume_config_patch,
    ],
    local.firewall_config_patches,
  ))

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

  # CRITICAL: Wait for Tailscale key to be created before generating config
  # Without this, the config is evaluated during planning before the key exists
  depends_on = [tailscale_tailnet_key.talos]

  lifecycle {
    # Validate resolved config before generating machine configuration.
    precondition {
      condition     = !strcontains(local.actual_cluster_endpoint, "<server-ip>")
      error_message = "Cluster endpoint still contains <server-ip> placeholder. The OVH server IP could not be resolved."
    }

    precondition {
      condition     = length(local.config_patches) >= 3
      error_message = "Expected at least 3 config patches (tailscale, zfs, cluster) but got ${length(local.config_patches)}. Check that required patches are not empty."
    }
  }
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
#
# When firewall is enabled, bootstrap uses the Tailscale IP because port 50000
# is blocked on the public IP from first boot. The Tailscale device is available
# before bootstrap (the extension starts on boot, before etcd init).
resource "talos_machine_bootstrap" "this" {
  depends_on = [
    ovh_dedicated_server_reinstall_task.talos,
    data.tailscale_device.talos_node,
  ]

  client_configuration = talos_machine_secrets.this.client_configuration
  node                 = var.enable_firewall ? local.tailscale_endpoint_ip : local.cluster_ip
  endpoint             = var.enable_firewall ? local.tailscale_endpoint_ip : local.cluster_ip

  lifecycle {
    # Force bootstrap to re-run when the server is reinstalled
    replace_triggered_by = [
      terraform_data.reinstall_trigger,
    ]

    precondition {
      condition = (
        !var.enable_firewall ||
        (local.tailscale_enabled && var.tailscale_device_lookup)
      )
      error_message = <<-EOT
        LOCKOUT: Firewall is enabled but bootstrap cannot reach the Talos API.
        The firewall blocks port 50000 on the public IP from first boot.
        Bootstrap must use the Tailscale IP, which requires:
        1. tailscale_hostname and tailscale_tailnet configured
        2. tailscale_device_lookup = true (with 'devices:read' OAuth scope)
      EOT
    }
  }
}

# Verify cluster health AFTER bootstrap completes
# This ensures the cluster is fully operational before Terraform finishes
# NOTE: When Tailscale is enabled, etcd advertises itself with the Tailscale IP (100.x.x.x),
# which causes the health check to fail because control_plane_nodes uses the public IP.
# We skip the health check when Tailscale is enabled since:
# 1. Bootstrap already waits for Talos API readiness
# 2. Tailscale IP is dynamically assigned and unknown to Terraform
# 3. User can verify health manually via: talosctl health --control-plane-nodes <tailscale-ip>
data "talos_cluster_health" "this" {
  count      = local.tailscale_enabled ? 0 : 1 # Skip when Tailscale is enabled
  depends_on = [talos_machine_bootstrap.this]

  client_configuration   = talos_machine_secrets.this.client_configuration
  endpoints              = local.talos_endpoints
  control_plane_nodes    = local.talos_nodes
  skip_kubernetes_checks = true # Only check Talos services, not full Kubernetes stack
}

# Extract kubeconfig for kubectl access
resource "talos_cluster_kubeconfig" "this" {
  depends_on = [talos_machine_bootstrap.this]

  client_configuration = talos_machine_secrets.this.client_configuration
  node                 = var.enable_firewall ? local.tailscale_endpoint_ip : local.cluster_ip
  endpoint             = var.enable_firewall ? local.tailscale_endpoint_ip : local.cluster_ip
}
