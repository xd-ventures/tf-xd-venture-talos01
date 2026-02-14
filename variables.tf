variable "ovh_endpoint" {
  description = "OVH API endpoint (ovh-eu, ovh-ca, ovh-us, etc.)"
  type        = string
  default     = "ovh-eu"
}

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

# Talos OS Configuration Variables

variable "talos_version" {
  description = "Talos OS version to deploy (e.g., v1.12.0)"
  type        = string

  validation {
    condition     = can(regex("^v\\d+\\.\\d+\\.\\d+$", var.talos_version))
    error_message = "talos_version must be a semantic version prefixed with 'v' (e.g., v1.12.0)."
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

# Cilium CNI Configuration Variables

variable "cilium_cli_version" {
  description = "Cilium CLI image version tag for the install Job. See: https://github.com/cilium/cilium-cli/releases"
  type        = string
  default     = "v0.19.0"

  validation {
    condition     = can(regex("^v\\d+\\.\\d+\\.\\d+$", var.cilium_cli_version))
    error_message = "cilium_cli_version must be a semantic version prefixed with 'v' (e.g., v0.19.0)."
  }
}

# Tailscale Configuration Variables
# NOTE: Auth key is always auto-generated via tailscale_tailnet_key resource
# This ensures fresh, single-use keys for each deployment

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
  description = "Extra arguments for Tailscale (e.g., --accept-routes, --advertise-exit-node)"
  type        = list(string)
  default     = []
}

variable "tailscale_tags" {
  description = "Tags to apply to the Tailscale device via the generated auth key (e.g., ['tag:k8s-cluster'])"
  type        = list(string)
  default     = ["tag:k8s-cluster"]
}

# Firewall Configuration Variables

variable "enable_firewall" {
  description = "Enable Talos firewall to block public IP access. Only enable after verifying Tailscale connectivity works."
  type        = bool
  default     = false
}

variable "pod_network_cidr" {
  description = "Pod network CIDR for CNI (Cilium with Kubernetes IPAM)"
  type        = string
  default     = "10.244.0.0/16"
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

# ArgoCD Configuration Variables

variable "argocd_enabled" {
  description = "Enable ArgoCD deployment. Set to true after cluster is bootstrapped and accessible."
  type        = bool
  default     = false
}

variable "argocd_chart_version" {
  description = "ArgoCD Helm chart version. See: https://github.com/argoproj/argo-helm/releases"
  type        = string
  # renovate: datasource=helm depName=argo-cd registryUrl=https://argoproj.github.io/argo-helm
  default = "7.9.1"
}

variable "argocd_server_insecure" {
  description = "Run ArgoCD server in insecure mode (no TLS). Safe when accessing via Tailscale + port-forward."
  type        = bool
  default     = true # Default true for easier local access via port-forward
}

variable "argocd_disable_admin" {
  description = "Disable the ArgoCD built-in admin account. Set to true after changing the initial admin password and configuring SSO or additional accounts."
  type        = bool
  default     = false
}

variable "argocd_deploy_guestbook" {
  description = "Deploy the ArgoCD guestbook example application to demonstrate GitOps workflow"
  type        = bool
  default     = false
}

# Shodan Network Monitoring Variables

variable "shodan_api_key" {
  description = "Shodan API key. Set via TF_VAR_shodan_api_key env var or -var flag. Get yours at https://account.shodan.io/"
  type        = string
  default     = ""
  sensitive   = true
}

variable "shodan_enabled" {
  description = "Enable Shodan network monitoring for the server's public IP."
  type        = bool
  default     = false
}

variable "shodan_triggers" {
  description = "Shodan alert triggers to enable. See: https://developer.shodan.io/api"
  type        = list(string)
  default = [
    "new_service",
    "vulnerable",
    "open_database",
    "ssl_expired",
    "internet_scanner",
    "iot",
  ]
}

variable "shodan_notifiers" {
  description = "Shodan notifier IDs for alert delivery (e.g., [\"default\"] for email). Configure notifiers in your Shodan account."
  type        = list(string)
  default     = ["default"]
}

# ZFS Pool Configuration Variables

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
