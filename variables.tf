variable "ovh_endpoint" {
  description = "OVH API endpoint (ovh-eu, ovh-ca, ovh-us, etc.)"
  type        = string
  default     = "ovh-eu"
}

variable "ovh_subsidiary" {
  description = "OVH subsidiary where the server was ordered (e.g., FR, DE, ES, GB, CA, US)"
  type        = string
}

variable "project_name" {
  description = "Project name for tagging and identification"
  type        = string
  default     = "talos01"
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

variable "install_disk" {
  description = "Disk device to install Talos on (e.g., /dev/sda, /dev/nvme0n1)"
  type        = string
  default     = "/dev/sda"
}

variable "use_raw_image" {
  description = "Use raw image format instead of qcow2 (recommended for OVH BYOI)"
  type        = bool
  default     = true  # Raw images are generally more reliable with OVH BYOI
}

variable "extra_kernel_args" {
  description = "Additional kernel arguments to pass to Talos (beyond the default for the platform)"
  type        = list(string)
  default     = []
  # Examples:
  # - "console=ttyS0" for serial console
  # - "net.ifnames=0" for classic network interface naming
}
