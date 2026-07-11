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

  # Default API IP: Tailscale when firewall is enabled (public IP blocked), public IP otherwise
  default_api_ip = var.enable_firewall ? local.tailscale_endpoint_ip : local.cluster_ip

  # Use explicit endpoints/nodes if provided, otherwise use default API IP
  talos_endpoints = length(var.talos_endpoints) > 0 ? var.talos_endpoints : [local.default_api_ip]
  talos_nodes = length(var.talos_nodes) > 0 ? var.talos_nodes : [local.default_api_ip
  ]

  # Talos factory installer image — used by the in-place upgrade resource
  # and the talos_installer_image output (single source of truth).
  talos_installer_image = "factory.talos.dev/installer/${talos_image_factory_schematic.this.id}:${var.talos_version}"

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

  # Pin the node hostname explicitly to the cluster name.
  # Without this, the hostname is derived from platform metadata (the OVH
  # config drive via platform=openstack). The v1.12->v1.13 upgrade regenerated
  # the boot cmdline as talos.platform=metal (the redundant talos.platform=
  # openstack arg had been removed), so the node stopped reading config-drive
  # metadata and fell back to a random talos-<hex> hostname — orphaning the
  # Kubernetes Node object. Pinning here makes the hostname independent of
  # platform detection on both the upgrade and reinstall paths.
  #
  # Talos 1.13 moved hostname into the dedicated HostnameConfig document and
  # auto-injects `auto: stable` (the source of the random talos-<hex> name).
  # A static `hostname` has the highest priority. It is mutually exclusive
  # with `auto` UNLESS auto is explicitly "off": we must set auto="off" so
  # this patch overrides the base config's auto="stable" rather than merging
  # into an invalid {auto: stable, hostname: ...} document. Setting the legacy
  # v1alpha1 machine.network.hostname instead fails validation with
  # "static hostname is already set in v1alpha1 config".
  hostname_config_patch = yamlencode({
    apiVersion = "v1alpha1"
    kind       = "HostnameConfig"
    auto       = "off"
    hostname   = var.cluster_name
  })

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

  # Talos API access for etcd backups (ADR-0018 decision 1, #316).
  # Grants ONLY the os:etcd:backup role, only to the talos-backup namespace.
  # Live-appliable machine config — deliberately NOT in the reinstall trigger
  # (main.tf tracks specific patch hashes; adding this patch must never
  # cascade a reinstall, cf. #268/#205).
  talos_backup_config_patch = var.talos_backup_enabled ? yamlencode({
    machine = {
      features = {
        kubernetesTalosAPIAccess = {
          enabled                     = true
          allowedRoles                = ["os:etcd:backup"]
          allowedKubernetesNamespaces = ["talos-backup"]
        }
      }
    }
  }) : ""

  # Cilium installation manifest
  # Uses Cilium CLI job to install Cilium with VXLAN tunnel routing
  # (pinned explicitly — see ADR-0015)
  # See templates/cilium-install-job.yaml.tftpl for the full manifest
  cilium_install_manifest = templatefile("${path.module}/templates/cilium-install-job.yaml.tftpl", {
    cilium_cli_image = var.cilium_cli_image
    cilium_version   = var.cilium_version
  })

  # ZFS pool setup manifest (only when enabled)
  # Uses a privileged Job with nsenter to run host ZFS/sfdisk binaries
  # See templates/zfs-pool-job.yaml.tftpl for the full manifest
  zfs_pool_manifest = var.zfs_pool_enabled ? templatefile("${path.module}/templates/zfs-pool-job.yaml.tftpl", {
    pool_name          = var.zfs_pool_name
    mount_point        = var.zfs_pool_mount_point
    disk_args          = join(" ", [for d in var.zfs_pool_disks : "${d.device}:${d.partition}"])
    zfs_pool_job_image = var.zfs_pool_job_image
  }) : ""

  # etcd backup CronJobs (talos-backup + daily decrypt-and-verify).
  # Non-secret manifests only — the S3/age Secret is created out-of-band
  # from the sensitive `talos_backup_secret_command` output, so no secret
  # material enters machine config, state-rendered manifests, or plan diffs.
  # See templates/talos-backup.yaml.tftpl and ADR-0018 decision 1.
  talos_backup_manifest = var.talos_backup_enabled ? templatefile("${path.module}/templates/talos-backup.yaml.tftpl", {
    backup_image   = var.talos_backup_image
    verify_image   = var.talos_backup_verify_image
    schedule       = var.talos_backup_schedule
    bucket         = var.talos_backup_s3_bucket
    s3_region      = var.talos_backup_s3_region
    s3_endpoint    = "https://s3.${var.talos_backup_s3_region}.io.cloud.ovh.net"
    cluster_name   = var.cluster_name
    age_public_key = var.talos_backup_age_public_key
  }) : ""

  # Cluster-level config patch: CNI, inline manifests, and scheduling
  # NOTE: Talos uses JSON merge patch (RFC 7396) — arrays are replaced, not appended.
  # All inline manifests MUST be in a single config patch to avoid overwrites.
  cluster_config_patch = yamlencode({
    cluster = {
      # Disable default Flannel CNI (Cilium replaces it).
      # Pod/service subnets are wired to the same variables the firewall
      # rules use (#244) so the two can never disagree. The values match the
      # Talos defaults; changing them triggers a full reinstall (both vars
      # are in the reinstall trigger) — cluster CIDRs cannot change in place.
      network = {
        cni = {
          name = "none"
        }
        podSubnets     = [var.pod_network_cidr]
        serviceSubnets = [var.service_network_cidr]
      }
      # kube-proxy is replaced by Cilium's eBPF kubeProxyReplacement;
      # running both is a conflict-prone double service-dataplane
      # (ADR-0015). NOTE: Talos's manifest controller is apply-only —
      # the already-bootstrapped DaemonSet was deleted manually (#286).
      proxy = {
        disabled = true
      }
      # Inline manifests: Cilium CNI install + optional ZFS pool setup
      inlineManifests = concat(
        [{ name = "cilium-install", contents = local.cilium_install_manifest }],
        var.zfs_pool_enabled ? [{ name = "zfs-pool-setup", contents = local.zfs_pool_manifest }] : [],
        var.talos_backup_enabled ? [{ name = "talos-backup", contents = local.talos_backup_manifest }] : []
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
      local.hostname_config_patch,
      local.tailscale_config_patch,
      local.certsans_config_patch,
      local.extra_host_entries_config_patch,
      local.zfs_config_patch,
      local.cluster_config_patch,
      local.ephemeral_volume_config_patch,
      local.talos_backup_config_patch,
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
  # Pinned — the provider's floating default breaks when it advances past
  # talos_version's supported range (issue #269). Kept OUT of the reinstall
  # trigger: version changes roll out live via talos_machine_configuration_apply.
  kubernetes_version = var.kubernetes_version

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

    # Feature-aware patch validation: assert each patch that should exist
    # rendered non-empty, instead of a flat count — a count check rejects
    # valid configurations with features disabled (issue #238), and compact()
    # silently drops empty strings, which these checks are meant to catch.
    precondition {
      condition     = local.zfs_config_patch != "" && local.cluster_config_patch != ""
      error_message = "A required config patch (zfs, cluster) rendered empty. Check the corresponding locals in talos.tf."
    }

    precondition {
      condition = !local.tailscale_enabled || (
        local.tailscale_config_patch != ""
        && local.certsans_config_patch != ""
        && local.extra_host_entries_config_patch != ""
      )
      error_message = "Tailscale is enabled but one of its config patches (tailscale, certSANs, extraHostEntries) rendered empty."
    }

    precondition {
      condition     = !var.zfs_pool_enabled || local.ephemeral_volume_config_patch != ""
      error_message = "zfs_pool_enabled is true but the EPHEMERAL volume config patch rendered empty."
    }

    precondition {
      condition     = !var.enable_firewall || length(local.firewall_config_patches) > 0
      error_message = "enable_firewall is true but no firewall config patches were generated."
    }

    precondition {
      condition = !var.talos_backup_enabled || (
        var.talos_backup_age_public_key != ""
        && var.talos_backup_s3_bucket != ""
        && var.ovh_cloud_project_id != ""
      )
      error_message = "talos_backup_enabled requires talos_backup_age_public_key, talos_backup_s3_bucket, and ovh_cloud_project_id to be set."
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
      # The manual tailscale_ip fallback (ADR-0009) is an accepted alternative
      # to the device lookup — tailscale_endpoint_ip resolves lookup > manual
      # override > public IP, and only the public-IP fallback is a lockout.
      condition = (
        !var.enable_firewall ||
        (local.tailscale_enabled && (var.tailscale_device_lookup || var.tailscale_ip != ""))
      )
      error_message = <<-EOT
        LOCKOUT: Firewall is enabled but bootstrap cannot reach the Talos API.
        The firewall blocks port 50000 on the public IP from first boot.
        Bootstrap must use the Tailscale IP, which requires:
        1. tailscale_hostname and tailscale_tailnet configured
        2. tailscale_device_lookup = true (with 'devices:read' OAuth scope),
           OR a manual tailscale_ip override (see ADR-0009 — you are
           responsible for keeping it current)
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

# Apply machine configuration to the running node.
#
# This is the primary mechanism for pushing config changes (inline manifests,
# network config, host entries, certSANs, etc.) to a running cluster WITHOUT
# triggering a reinstall. Changes that don't require a reboot are applied
# immediately; changes that do (like firewall rules) are staged for next boot.
#
# See ADR-0013 for the upgrade lifecycle architecture.
resource "talos_machine_configuration_apply" "controlplane" {
  # Serialized after the in-place upgrade: on a version bump in upgrade mode
  # both resources change, and applying config mid-upgrade-reboot fails
  # nondeterministically (#210 review).
  depends_on = [talos_machine_bootstrap.this, terraform_data.talos_upgrade]

  client_configuration        = talos_machine_secrets.this.client_configuration
  machine_configuration_input = data.talos_machine_configuration.controlplane.machine_configuration
  node                        = local.default_api_ip
  endpoint                    = local.default_api_ip

  # auto: apply immediately when possible, reboot only if the change requires it.
  # For .cluster changes (inline manifests): applied live, no reboot.
  # For firewall rules (NetworkRuleConfig): staged for next reboot.
  apply_mode = "auto"

}

# In-place Talos upgrade (ADR-0013 Phase 2, #210).
#
# Active only with upgrade_mode = "upgrade": version/extension changes flow
# into the factory installer image, which replaces this resource and runs
# `talosctl upgrade --stage --preserve --wait` via local-exec.
# - --stage: install before ZFS mounts are active (siderolabs/talos#8800)
# - --preserve: keep EPHEMERAL (etcd cannot rebuild from peers on one node)
# - A/B boot partitions give automatic rollback on a failed boot
#
# The guard skips the upgrade when the node already runs the target version
# AND schematic (e.g. right after flipping upgrade_mode, whose resource
# creation would otherwise trigger a same-version upgrade + reboot).
#
# Requires talosctl and a talosconfig (./talosconfig or $TALOSCONFIG) where
# `tofu apply` runs — not wired into the GitOps CI runner (see
# docs/guides/GITOPS_SETUP.md).
resource "terraform_data" "talos_upgrade" {
  count = var.upgrade_mode == "upgrade" ? 1 : 0

  triggers_replace = [
    local.talos_installer_image,
  ]

  depends_on = [talos_machine_bootstrap.this]

  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]
    command     = <<-EOT
      set -euo pipefail
      TC="$${TALOSCONFIG:-$PWD/talosconfig}"
      if [ ! -f "$TC" ]; then
        echo "ERROR: talosconfig not found at $TC." >&2
        echo "Run: tofu output -raw talosconfig > talosconfig (or set TALOSCONFIG)." >&2
        exit 1
      fi
      NODE="${local.default_api_ip}"
      IMAGE="${local.talos_installer_image}"

      # Skip when the node already runs the target version AND schematic.
      # The SERVER version is extracted explicitly — `version --short` also
      # prints the CLIENT version, and a bare grep would false-match when the
      # operator's talosctl equals the target (#210 review), silently
      # skipping a needed upgrade. Exact match also avoids v1.12.3 matching
      # v1.12.30.
      VER_OUT="$(talosctl --talosconfig "$TC" -n "$NODE" -e "$NODE" version --short 2>/dev/null || true)"
      EXT_OUT="$(talosctl --talosconfig "$TC" -n "$NODE" -e "$NODE" get extensions 2>/dev/null || true)"
      # Server section format (verified on talosctl 1.12.x): "Server:" then
      # tab-indented fields; the version is the "Tag:" line.
      SRV_VER="$(printf '%s\n' "$VER_OUT" | awk '/^Server:/{s=1;next} s && $1=="Tag:"{print $2; exit}')"
      if [[ "$SRV_VER" == "${var.talos_version}" && "$EXT_OUT" == *"${talos_image_factory_schematic.this.id}"* ]]; then
        echo "Node already runs ${var.talos_version} with the target schematic - nothing to upgrade."
        exit 0
      fi

      # --preserve is deprecated-hidden on modern talosctl (preservation is
      # the default there) but still REQUIRED on the legacy upgrade path —
      # omitting it there silently loses etcd. Keep it until talosctl 1.18
      # removes the flag (loud failure, one-line fix then).
      echo "In-place upgrade to $IMAGE (staged, preserving EPHEMERAL; the node will reboot)..."
      talosctl --talosconfig "$TC" -n "$NODE" -e "$NODE" \
        upgrade --image "$IMAGE" --stage --preserve --wait --timeout 30m
      echo "Upgrade complete."
    EOT
  }
}

# Extract kubeconfig for kubectl access
resource "talos_cluster_kubeconfig" "this" {
  depends_on = [talos_machine_bootstrap.this]

  client_configuration = talos_machine_secrets.this.client_configuration
  node                 = var.enable_firewall ? local.tailscale_endpoint_ip : local.cluster_ip
  endpoint             = var.enable_firewall ? local.tailscale_endpoint_ip : local.cluster_ip
}
