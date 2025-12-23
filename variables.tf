variable "ovh_endpoint" {
  description = "OVH API endpoint (ovh-eu, ovh-ca, ovh-us, etc.)"
  type        = string
  default     = "ovh-eu"
}

variable "service_name" {
  description = "The service name of the OVH bare metal server"
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
