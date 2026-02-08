variable "ovh_endpoint" {
  description = "OVH API endpoint (ovh-eu, ovh-ca, ovh-us, etc.)"
  type        = string
  default     = "ovh-eu"
}

variable "ovh_subsidiary" {
  description = "OVH subsidiary where the server was ordered (e.g., FR, DE, ES, GB, CA, US)"
  type        = string
}

variable "monitoring_enabled" {
  description = "Enable or disable OVH monitoring for the server"
  type        = bool
  default     = false  # Typically disabled for Talos as it doesn't respond to OVH monitoring
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
}

variable "cluster_name" {
  description = "Name of the Kubernetes cluster"
  type        = string
}

variable "cluster_endpoint" {
  description = "Kubernetes API endpoint URL (e.g., https://<server-ip>:6443)"
  type        = string
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
}

variable "use_raw_image" {
  description = "Use raw image format (.raw.xz) instead of qcow2. Default is false (qcow2) as it's been verified to work well with OVH BYOI."
  type        = bool
  default     = false  # QCOW2 format is default as it's been tested and works reliably
}

variable "extra_kernel_args" {
  description = "Additional kernel arguments to pass to Talos (beyond the default for the platform)"
  type        = list(string)
  default     = []
  # Examples:
  # - "console=ttyS0" for serial console
  # - "net.ifnames=0" for classic network interface naming
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
  description = "Manual Tailscale IP override. Used as fallback when device lookup is disabled or fails."
  type        = string
  default     = ""
}

variable "tailscale_device_lookup" {
  description = "Auto-discover Tailscale IP via API. Set false for fresh deploys where device doesn't exist yet. See ADR-0009."
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
  default     = "7.7.16"  # Latest stable as of December 2024
}

variable "argocd_server_insecure" {
  description = "Run ArgoCD server in insecure mode (no TLS). Safe when accessing via Tailscale + port-forward."
  type        = bool
  default     = true  # Default true for easier local access via port-forward
}

variable "argocd_deploy_guestbook" {
  description = "Deploy the ArgoCD guestbook example application to demonstrate GitOps workflow"
  type        = bool
  default     = false
}
