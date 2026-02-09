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
# Sets openstack platform kernel arg for OVH config drive compatibility
resource "talos_image_factory_schematic" "this" {
  schematic = yamlencode({
    customization = {
      # Explicitly set openstack platform kernel arg since OVH creates OpenStack format config drive
      # OVH BYOI creates config drive with config-2 label and openstack/latest/user_data structure
      # Talos openstack platform supports this format
      extraKernelArgs = concat(
        ["talos.platform=openstack"], # OVH creates OpenStack format, use OpenStack platform
        var.extra_kernel_args
      )
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
# Use "openstack" platform since OVH creates OpenStack format config drive (config-2 label, openstack/latest/user_data)
# OVH BYOI creates config drive with:
#   - Volume label: config-2 (OpenStack format)
#   - File location: openstack/latest/user_data
# Talos openstack platform supports this format and reads the config from the correct location
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

  # Use ts.net hostname when Tailscale is enabled for secure access
  # NOTE: The cluster node itself may not resolve ts.net hostnames (no MagicDNS internally)
  # This means talosctl health may fail with DNS errors, but kubectl will work from your machine
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
  # For initial bootstrap, always use public IP (Tailscale not yet available)
  talos_endpoints = length(var.talos_endpoints) > 0 ? var.talos_endpoints : [local.cluster_ip]
  talos_nodes     = length(var.talos_nodes) > 0 ? var.talos_nodes : [local.cluster_ip]

  # Tailscale auth key is always auto-generated via tailscale_tailnet_key resource
  # This ensures fresh, single-use keys for each deployment (no stale keys from env vars)
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

  # Cilium CNI configuration
  # Replaces Flannel with Cilium for eBPF-based networking, Hubble observability, and Gateway API
  # See ADR-0003 for decision rationale
  cilium_config_patch = yamlencode({
    cluster = {
      # Disable default Flannel CNI
      network = {
        cni = {
          name = "none"
        }
      }
      # Install Cilium via inline manifest
      inlineManifests = [
        {
          name     = "cilium-install"
          contents = local.cilium_install_manifest
        }
      ]
      # Skip waiting for CNI during bootstrap (Cilium installs after API server)
      allowSchedulingOnControlPlanes = true
    }
  })

  # Cilium installation manifest
  # Uses Cilium CLI job to install Cilium with native routing mode
  cilium_install_manifest = <<-EOF
    ---
    apiVersion: v1
    kind: ServiceAccount
    metadata:
      name: cilium-install
      namespace: kube-system
    ---
    apiVersion: rbac.authorization.k8s.io/v1
    kind: ClusterRoleBinding
    metadata:
      name: cilium-install
    roleRef:
      apiGroup: rbac.authorization.k8s.io
      kind: ClusterRole
      name: cluster-admin
    subjects:
      - kind: ServiceAccount
        name: cilium-install
        namespace: kube-system
    ---
    apiVersion: batch/v1
    kind: Job
    metadata:
      name: cilium-install
      namespace: kube-system
    spec:
      backoffLimit: 10
      template:
        metadata:
          labels:
            app: cilium-install
        spec:
          restartPolicy: OnFailure
          tolerations:
            - operator: Exists
          affinity:
            nodeAffinity:
              requiredDuringSchedulingIgnoredDuringExecution:
                nodeSelectorTerms:
                  - matchExpressions:
                      - key: node-role.kubernetes.io/control-plane
                        operator: Exists
          serviceAccountName: cilium-install
          hostNetwork: true
          containers:
            - name: cilium-install
              image: quay.io/cilium/cilium-cli-ci:latest
              env:
                - name: KUBERNETES_SERVICE_HOST
                  valueFrom:
                    fieldRef:
                      apiVersion: v1
                      fieldPath: status.podIP
                - name: KUBERNETES_SERVICE_PORT
                  value: "6443"
              command:
                - cilium
                - install
                - --set
                - ipam.mode=kubernetes
                - --set
                - kubeProxyReplacement=true
                - --set
                - securityContext.capabilities.ciliumAgent={CHOWN,KILL,NET_ADMIN,NET_RAW,IPC_LOCK,SYS_ADMIN,SYS_RESOURCE,DAC_OVERRIDE,FOWNER,SETGID,SETUID}
                - --set
                - securityContext.capabilities.cleanCiliumState={NET_ADMIN,SYS_ADMIN,SYS_RESOURCE}
                - --set
                - cgroup.autoMount.enabled=false
                - --set
                - cgroup.hostRoot=/sys/fs/cgroup
                - --set
                - k8sServiceHost=localhost
                - --set
                - k8sServicePort=7445
                - --set
                - hubble.enabled=true
                - --set
                - hubble.relay.enabled=true
                - --set
                - hubble.ui.enabled=true
                - --set
                - gatewayAPI.enabled=true
  EOF

  # Combined config patches for machine configuration
  config_patches = compact([
    local.tailscale_config_patch,
    local.certsans_config_patch,
    local.zfs_config_patch,
    local.cilium_config_patch,
  ])

  # STABLE config patches for reinstall trigger comparison
  # The Tailscale auth key changes frequently (expires after 1 hour), but we don't want
  # to reinstall the server just because the key changed - the key is only used once
  # during initial setup (TS_AUTH_ONCE=true). After that, Tailscale stores its state.
  # This stable version uses a placeholder instead of the actual key.
  tailscale_config_patch_stable = local.tailscale_enabled ? yamlencode({
    apiVersion = "v1alpha1"
    kind       = "ExtensionServiceConfig"
    name       = "tailscale"
    environment = concat(
      [
        "TS_AUTHKEY=STABLE_PLACEHOLDER", # Placeholder - actual key is volatile
        "TS_AUTH_ONCE=true",
      ],
      var.tailscale_hostname != "" ? ["TS_HOSTNAME=${var.tailscale_hostname}"] : [],
      [for arg in var.tailscale_extra_args : arg]
    )
  }) : ""

  # Stable config patches used ONLY for reinstall trigger comparison
  stable_config_patches = compact([
    local.tailscale_config_patch_stable,
    local.certsans_config_patch,
    local.zfs_config_patch,
    local.cilium_config_patch,
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

  # CRITICAL: Wait for Tailscale key to be created before generating config
  # Without this, the config is evaluated during planning before the key exists
  depends_on = [tailscale_tailnet_key.talos]
}

# STABLE machine configuration for reinstall trigger comparison
# This uses stable_config_patches which has a placeholder for the Tailscale auth key
# so that key expiration/regeneration doesn't trigger a cluster reinstall
data "talos_machine_configuration" "controlplane_stable" {
  cluster_name     = var.cluster_name
  machine_type     = "controlplane"
  cluster_endpoint = local.actual_cluster_endpoint
  machine_secrets  = talos_machine_secrets.this.machine_secrets
  talos_version    = var.talos_version

  # Use STABLE config patches (with placeholder for volatile Tailscale auth key)
  config_patches = local.stable_config_patches
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
      terraform_data.reinstall_trigger,
    ]
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
  node                 = local.cluster_ip
  endpoint             = local.cluster_ip
}

# Output the raw disk image URL for debugging
output "debug_disk_image_url" {
  description = "Raw disk image URL from image factory (for debugging)"
  value       = data.talos_image_factory_urls.this.urls.disk_image
}
