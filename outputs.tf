# Server Outputs
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

# Talos Configuration Outputs
output "talos_schematic_id" {
  description = "The Talos image factory schematic ID"
  value       = talos_image_factory_schematic.this.id
}

output "talos_image_url" {
  description = "The Talos image URL being deployed"
  value       = local.image_url
}

output "talos_installer_image" {
  description = "The Talos installer image for upgrades"
  value       = "factory.talos.dev/installer/${talos_image_factory_schematic.this.id}:${var.talos_version}"
}

output "cluster_endpoint" {
  description = "Kubernetes API endpoint URL"
  value       = var.cluster_endpoint
}

# Sensitive outputs - use with care
output "talos_machine_config" {
  description = "Base64 encoded machine configuration (for manual apply if needed)"
  value       = base64encode(data.talos_machine_configuration.controlplane.machine_configuration)
  sensitive   = true
}

output "talos_machine_config_raw" {
  description = "Raw machine configuration YAML (for debugging - shows what goes to config drive)"
  value       = data.talos_machine_configuration.controlplane.machine_configuration
  sensitive   = true
}

output "config_drive_user_data_info" {
  description = "Information about config drive user-data (size/length for verification). Use 'tofu output config_drive_user_data_info' to view."
  value = {
    length_bytes = length(data.talos_machine_configuration.controlplane.machine_configuration)
    first_100_chars = substr(data.talos_machine_configuration.controlplane.machine_configuration, 0, min(100, length(data.talos_machine_configuration.controlplane.machine_configuration)))
  }
  sensitive = true
}

output "talosconfig" {
  description = "Talos client configuration for talosctl - ready to use YAML file"
  value       = data.talos_client_configuration.this.talos_config
  sensitive   = true
}

output "talosconfig_save_command" {
  description = "Command to save talosconfig to file"
  value       = "tofu output -raw talosconfig > talosconfig"
}

output "config_drive_debug_info" {
  description = "Debug information about config drive configuration"
  value = {
    user_data_length      = length(data.talos_machine_configuration.controlplane.machine_configuration)
    user_data_starts_with = substr(data.talos_machine_configuration.controlplane.machine_configuration, 0, 20)
    cluster_endpoint      = replace(var.cluster_endpoint, "<server-ip>", ovh_dedicated_server.talos01.ip)
    metadata_instance_id = var.cluster_name
    note                  = "OVH creates OpenStack format (config-2, openstack/latest/user_data). Talos OpenStack platform supports this format."
  }
  sensitive = true
}

output "bootstrap_completed" {
  description = "Indicates when the Talos cluster bootstrap was completed"
  value       = talos_machine_bootstrap.this.id
}

# Debug outputs - useful for troubleshooting
output "debug_image_factory_urls" {
  description = "All available URLs from image factory"
  value = {
    disk_image    = data.talos_image_factory_urls.this.urls.disk_image
    iso           = try(data.talos_image_factory_urls.this.urls.iso, "N/A")
    installer     = try(data.talos_image_factory_urls.this.urls.installer, "N/A")
    kernel        = try(data.talos_image_factory_urls.this.urls.kernel, "N/A")
    initramfs     = try(data.talos_image_factory_urls.this.urls.initramfs, "N/A")
  }
}

# Kubernetes access
output "kubeconfig" {
  description = "Kubernetes admin configuration for kubectl - ready to use YAML file"
  value       = talos_cluster_kubeconfig.this.kubeconfig_raw
  sensitive   = true
}

output "kubeconfig_save_command" {
  description = "Command to save kubeconfig to file"
  value       = "tofu output -raw kubeconfig > kubeconfig"
}
