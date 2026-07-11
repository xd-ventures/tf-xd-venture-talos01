# SPDX-License-Identifier: Apache-2.0
# Copyright Maciej Sawicki

# Input variables for the talos-cluster module. Definitions mirror the
# consumer root (same descriptions/validations/defaults) so the two never
# drift; the consumer passes every value explicitly (module defaults are a
# fallback for standalone use / the VM instance).

variable "ovh_subsidiary" {
  description = "OVH subsidiary where the server was ordered (e.g., FR, DE, ES, GB, CA, US)"
  type        = string

  validation {
    condition     = contains(["ASIA", "AU", "CA", "CZ", "DE", "ES", "EU", "FI", "FR", "GB", "IE", "IN", "IT", "LT", "MA", "NL", "PL", "PT", "QC", "SG", "SN", "TN", "US", "WE", "WS"], var.ovh_subsidiary)
    error_message = "ovh_subsidiary must be a valid OVH subsidiary code (e.g., FR, DE, US, CA, GB)."
  }
}

variable "monitoring_enabled" {
  description = "Enable or disable OVH monitoring for the server"
  type        = bool
  default     = false # Typically disabled for Talos as it doesn't respond to OVH monitoring
}

variable "server_state" {
  description = "Desired state of the server (ok, disabled, etc.)"
  type        = string
  default     = "ok"
}

variable "talos_version" {
  description = "Talos OS version to deploy (e.g., v1.12.0)"
  type        = string

  validation {
    condition     = can(regex("^v\\d+\\.\\d+\\.\\d+$", var.talos_version))
    error_message = "talos_version must be a semantic version prefixed with 'v' (e.g., v1.12.0)."
  }
}

variable "kubernetes_version" {
  description = "Kubernetes version for the generated machine configuration (bare semver, e.g. 1.36.2). Must be within talos_version's supported range. Changes apply in-place via talos_machine_configuration_apply — no reinstall."
  type        = string
  default     = "1.36.2"

  validation {
    condition     = can(regex("^\\d+\\.\\d+\\.\\d+$", var.kubernetes_version))
    error_message = "kubernetes_version must be a bare semantic version without 'v' prefix (e.g., 1.35.0)."
  }
}

variable "upgrade_mode" {
  description = <<-EOT
    How talos_version / talos_extensions changes are applied (ADR-0013 Phase 2):

    "reinstall" (default): version/extension changes trigger a full OVH BYOI
    reinstall — wipes etcd and ZFS pools (back up first; see the runbook).

    "upgrade": version/extension changes run `talosctl upgrade --stage
    --preserve --wait` in-place via a local-exec provisioner — etcd, ZFS
    pools, and Tailscale identity survive; A/B boot partitions give automatic
    rollback. Requires talosctl and a valid talosconfig (./talosconfig or
    $TALOSCONFIG) wherever `tofu apply` runs — NOT yet wired into the GitOps
    CI runner.

    WARNING: FLIPPING this value restructures the reinstall trigger list and
    therefore cascades ONE full reinstall on the next apply (in either
    direction). Flip it bundled with a planned reinstall, or use the
    state-surgery procedure documented in the Operations Runbook (#268) to
    flip without one.
  EOT
  type        = string
  default     = "reinstall"

  validation {
    condition     = contains(["reinstall", "upgrade"], var.upgrade_mode)
    error_message = "upgrade_mode must be 'reinstall' or 'upgrade'."
  }
}

variable "cluster_name" {
  description = "Name of the Kubernetes cluster"
  type        = string
}

variable "cluster_endpoint" {
  description = "Kubernetes API endpoint URL (e.g., https://<server-ip>:6443)"
  type        = string

  validation {
    condition     = can(regex("^https://", var.cluster_endpoint))
    error_message = "cluster_endpoint must start with https:// (e.g., https://<server-ip>:6443)."
  }
}

variable "talos_endpoints" {
  description = "List of Talos API endpoints (control plane nodes). If not set, extracted from cluster_endpoint."
  type        = list(string)
  default     = []
}

variable "talos_nodes" {
  description = "List of Talos node IPs for talosctl operations. If not set, extracted from cluster_endpoint."
  type        = list(string)
  default     = []
}

variable "talos_extensions" {
  description = "List of additional Talos system extensions to include from image factory"
  type        = list(string)
  default     = []
}

variable "architecture" {
  description = "CPU architecture for Talos OS image"
  type        = string
  default     = "amd64"

  validation {
    condition     = contains(["amd64", "arm64"], var.architecture)
    error_message = "architecture must be 'amd64' or 'arm64'."
  }
}

variable "use_raw_image" {
  description = "Use raw image format (.raw.xz) instead of qcow2. Default is false (qcow2) as it's been verified to work well with OVH BYOI."
  type        = bool
  default     = false # QCOW2 format is default as it's been tested and works reliably
}

variable "extra_kernel_args" {
  description = "Additional kernel arguments to pass to Talos (beyond the default for the platform)"
  type        = list(string)
  default     = []
  # Examples:
  # - "console=ttyS0" for serial console
  # - "net.ifnames=0" for classic network interface naming
}

variable "cilium_cli_image" {
  description = "Cilium CLI image (repo:tag@digest) for the install Job. See: https://github.com/cilium/cilium-cli/releases"
  type        = string
  # renovate: datasource=docker depName=quay.io/cilium/cilium-cli-ci
  default = "quay.io/cilium/cilium-cli-ci:v0.18.2@sha256:503324c1fc7027e0daeb251ca2d4ad6b42d73c6be7a89cb8057cce8e59e50393"

  validation {
    condition     = can(regex("^[\\w./-]+:[\\w.-]+@sha256:[a-f0-9]{64}$", var.cilium_cli_image))
    error_message = "cilium_cli_image must be in repo:tag@sha256:<digest> form."
  }
}

variable "cilium_version" {
  description = "Cilium chart version installed (fresh bootstrap) or reconciled to (cilium upgrade on re-runs) by the install Job. Pinned so upgrades are deterministic instead of following the CLI's embedded default."
  type        = string
  # renovate: datasource=helm depName=cilium registryUrl=https://helm.cilium.io/
  default = "1.17.0"

  validation {
    condition     = can(regex("^\\d+\\.\\d+\\.\\d+$", var.cilium_version))
    error_message = "cilium_version must be a bare semantic version (e.g., 1.17.0)."
  }
}

variable "zfs_pool_job_image" {
  description = "Utility image (repo:tag@digest) for the ZFS pool setup Job."
  type        = string
  # renovate: datasource=docker depName=alpine
  default = "alpine:3.21@sha256:c3f8e73fdb79deaebaa2037150150191b9dcbfba68b4a46d70103204c53f4709"

  validation {
    condition     = can(regex("^[\\w./-]+:[\\w.-]+@sha256:[a-f0-9]{64}$", var.zfs_pool_job_image))
    error_message = "zfs_pool_job_image must be in repo:tag@sha256:<digest> form."
  }
}

variable "tailscale_hostname" {
  description = "Hostname for the Tailscale node (without .ts.net suffix)"
  type        = string
  default     = ""
}

variable "tailscale_tailnet" {
  description = "Tailnet name for ts.net DNS (e.g., 'tail1234' from hostname.tail1234.ts.net)"
  type        = string
  default     = ""
}

variable "tailscale_ip" {
  description = <<-EOT
    Manual Tailscale IP override. Only used when tailscale_device_lookup is false.

    You are responsible for keeping this value current. Tailscale IPs change on device
    re-registration, which means this value can become stale after reinstalls. A stale IP
    will cause firewall configuration to target a non-existent endpoint. Prefer
    tailscale_device_lookup = true to avoid this class of issue.
  EOT
  type        = string
  default     = ""

  validation {
    condition     = var.tailscale_ip == "" || can(cidrhost("${var.tailscale_ip}/32", 0))
    error_message = "tailscale_ip must be a valid IPv4 address (e.g., 100.64.1.42) or empty."
  }
}

variable "tailscale_device_lookup" {
  description = <<-EOT
    Auto-discover Tailscale IP via API after bootstrap. Recommended for all deployments.

    When true (default): Queries Tailscale API for the device's current 100.x.y.z IP.
    This keeps the cluster endpoint and firewall configuration correct across reinstalls
    without manual intervention. Requires 'devices:read' OAuth scope (see ADR-0008).

    When false: Falls back to manual tailscale_ip variable. If tailscale_ip is also empty,
    uses the public IP — which will cause lockout if the firewall is enabled. This path
    requires manual IP management on every reinstall and is not validated by the project
    maintainers. See ADR-0009 for details.
  EOT
  type        = bool
  default     = true
}

variable "tailscale_extra_args" {
  description = "Extra environment entries for the Tailscale extension in TS_* KEY=VALUE form (e.g., [\"TS_ACCEPT_ROUTES=true\", \"TS_ADVERTISE_EXIT_NODE=true\"]). These are ExtensionServiceConfig environment variables, NOT CLI flags — flag-style values would be silently ignored by the extension."
  type        = list(string)
  default     = []

  validation {
    condition     = alltrue([for a in var.tailscale_extra_args : can(regex("^TS_[A-Z0-9_]+=", a))])
    error_message = "Each tailscale_extra_args entry must be a TS_* environment variable in KEY=VALUE form (e.g., TS_ACCEPT_ROUTES=true). CLI flags like --accept-routes are not supported by the Talos Tailscale extension."
  }
}

variable "tailscale_tags" {
  description = "Tags to apply to the Tailscale device via the generated auth key (e.g., ['tag:k8s-cluster'])"
  type        = list(string)
  default     = ["tag:k8s-cluster"]
}

variable "enable_firewall" {
  description = "Enable Talos firewall from first boot. Bakes NetworkDefaultActionConfig + NetworkRuleConfig into the config drive. All ingress blocked except Tailscale, localhost, and cluster CIDRs. Bootstrap uses Tailscale IP. Toggling requires reinstall."
  type        = bool
  default     = false
}

variable "pod_network_cidr" {
  description = "Pod network CIDR — wired into both the cluster config (podSubnets) and the firewall rules so they cannot disagree (#244). Changing it triggers a full reinstall (cluster CIDRs cannot change in place)."
  type        = string
  default     = "10.244.0.0/16"
}

variable "service_network_cidr" {
  description = "Kubernetes service network CIDR (ClusterIP range) — wired into both the cluster config (serviceSubnets) and the firewall rules so they cannot disagree (#244). Changing it triggers a full reinstall (cluster CIDRs cannot change in place)."
  type        = string
  default     = "10.96.0.0/12"
}

variable "tailscale_ipv4_cidr" {
  description = "Tailscale IPv4 CIDR range"
  type        = string
  default     = "100.64.0.0/10"
}

variable "tailscale_ipv6_cidr" {
  description = "Tailscale IPv6 CIDR range"
  type        = string
  default     = "fd7a:115c:a1e0::/48"
}

variable "zfs_pool_enabled" {
  description = "Enable automated ZFS pool creation via inline manifest Job. When false (default), no ZFS pool resources are created."
  type        = bool
  default     = false
}

variable "zfs_pool_name" {
  description = "Name of the ZFS pool to create"
  type        = string
  default     = "tank"
}

variable "zfs_pool_mount_point" {
  description = "Mount point for the ZFS pool"
  type        = string
  default     = "/var/mnt/data"
}

variable "zfs_pool_disks" {
  description = "List of disks and partition numbers for the ZFS mirror pool. Each entry specifies a device and the partition number to create."
  type = list(object({
    device    = string # e.g., "/dev/nvme0n1"
    partition = number # partition number to create
  }))
  default = []

  validation {
    condition     = !var.zfs_pool_enabled || length(var.zfs_pool_disks) >= 2
    error_message = "At least 2 disks are required for a ZFS mirror pool when zfs_pool_enabled is true."
  }
}

variable "ephemeral_max_size" {
  description = "Maximum size for the Talos EPHEMERAL partition. Limits /var to free disk space for ZFS. Only applied on fresh installs."
  type        = string
  default     = "100GiB"

  validation {
    condition     = can(regex("^[0-9]+(MiB|GiB|TiB)$", var.ephemeral_max_size))
    error_message = "ephemeral_max_size must be a number followed by a Talos size unit (MiB, GiB, or TiB), e.g. \"100GiB\"."
  }
}

variable "talos_backup_enabled" {
  description = "Deploy the talos-backup CronJob (etcd snapshot → zstd → age → S3) plus a daily decrypt-and-verify CronJob. Requires talos_backup_age_public_key, talos_backup_s3_bucket, and ovh_cloud_project_id."
  type        = bool
  default     = false
}

variable "talos_backup_age_public_key" {
  description = "age X25519 recipient (public key, age1…) that etcd snapshots are encrypted to. The PRIVATE key is never stored in this configuration — custody per ADR-0018 decision 4 (password manager + offline media)."
  type        = string
  default     = ""

  validation {
    condition     = var.talos_backup_age_public_key == "" || can(regex("^age1[a-z0-9]{58}$", var.talos_backup_age_public_key))
    error_message = "talos_backup_age_public_key must be an age X25519 recipient (age1…, 62 chars) or empty."
  }
}

variable "talos_backup_s3_bucket" {
  description = "Name of the dedicated S3 bucket for etcd snapshots (created by this configuration; must be globally unique within the OVH region)."
  type        = string
  default     = ""
}

variable "talos_backup_s3_region" {
  description = "OVH Object Storage region for the backup bucket (lowercase, e.g. gra / sbg / waw). Endpoint is derived as https://s3.<region>.io.cloud.ovh.net."
  type        = string
  default     = "gra"
}

variable "talos_backup_schedule" {
  description = "Cron schedule for etcd snapshots (ADR-0018: every 4–6 h)."
  type        = string
  default     = "15 */6 * * *"
}

variable "ovh_cloud_project_id" {
  description = "OVH Public Cloud project ID (serviceName) hosting the backup bucket and its dedicated write-only S3 user. Sensitive: infrastructure identifier in a public repo (#300)."
  type        = string
  default     = ""
  sensitive   = true
}

variable "talos_backup_image" {
  description = "talos-backup image (repo:tag@digest). Official Sidero image; pre-release only — the tool is minimal-but-official (ADR-0018 accepted risk, mitigated by the verify CronJob and drills)."
  type        = string
  # renovate: datasource=docker depName=ghcr.io/siderolabs/talos-backup
  default = "ghcr.io/siderolabs/talos-backup:v0.1.0-beta.3@sha256:05c86663b251a407551dc948097e32e163a345818117eb52c573b0447bd0c7a7"

  validation {
    condition     = can(regex("^[\\w./-]+:[\\w.-]+@sha256:[a-f0-9]{64}$", var.talos_backup_image))
    error_message = "talos_backup_image must be in repo:tag@sha256:<digest> form."
  }
}

variable "talos_backup_verify_image" {
  description = "Utility image (repo:tag@digest) for the daily decrypt-and-verify CronJob (needs apk: aws-cli, age, zstd)."
  type        = string
  # renovate: datasource=docker depName=alpine
  default = "alpine:3.21@sha256:c3f8e73fdb79deaebaa2037150150191b9dcbfba68b4a46d70103204c53f4709"

  validation {
    condition     = can(regex("^[\\w./-]+:[\\w.-]+@sha256:[a-f0-9]{64}$", var.talos_backup_verify_image))
    error_message = "talos_backup_verify_image must be in repo:tag@sha256:<digest> form."
  }
}
