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
  default     = true
}

variable "server_state" {
  description = "Desired state of the server (active, disabled, etc.)"
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

variable "talos_extensions" {
  description = "List of Talos system extensions to include from image factory"
  type        = list(string)
  default     = []
}

variable "architecture" {
  description = "CPU architecture for Talos OS image"
  type        = string
  default     = "amd64"
}
