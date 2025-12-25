output "server_id" {
  description = "The service name/ID of the bare metal server"
  value       = ovh_dedicated_server.talos01.service_name
}

output "server_name" {
  description = "The name of the bare metal server"
  value       = ovh_dedicated_server.talos01.display_name
}

output "server_state" {
  description = "The current state of the bare metal server"
  value       = ovh_dedicated_server.talos01.state
}

output "server_ip" {
  description = "The IP address of the bare metal server"
  value       = ovh_dedicated_server.talos01.ip
}

output "server_monitoring" {
  description = "Monitoring status of the server"
  value       = ovh_dedicated_server.talos01.monitoring
}

# Talos OS Outputs

output "talos_image_url" {
  description = "The qcow2 image URL from Talos image factory"
  value       = replace(data.talos_image_factory_urls.this.urls.disk_image, ".raw.zst", ".qcow2")
}

output "talos_machine_config" {
  description = "Base64 encoded machine configuration for Talos OS"
  value       = base64encode(data.talos_machine_configuration.controlplane.machine_configuration)
  sensitive   = true
}

output "cluster_endpoint" {
  description = "Kubernetes API endpoint URL"
  value       = var.cluster_endpoint
}

# Note: talosconfig output removed - the attribute may not be available in the data source
# Use talos_machine_secrets resource or talos_client_configuration resource separately if needed
# output "talosconfig" {
#   description = "Talos client configuration for talosctl access"
#   value       = data.talos_machine_configuration.controlplane.client_configuration
#   sensitive   = true
# }
