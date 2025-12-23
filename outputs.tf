output "server_id" {
  description = "The service name/ID of the bare metal server"
  value       = data.ovh_dedicated_server.talos01.service_name
}

output "server_name" {
  description = "The name of the bare metal server"
  value       = data.ovh_dedicated_server.talos01.name
}

output "server_state" {
  description = "The current state of the bare metal server"
  value       = data.ovh_dedicated_server.talos01.state
}

output "server_ip" {
  description = "The IP address of the bare metal server"
  value       = data.ovh_dedicated_server.talos01.ip
}

output "server_datacenter" {
  description = "The datacenter location of the bare metal server"
  value       = data.ovh_dedicated_server.talos01.datacenter
}

output "server_commercial_range" {
  description = "The commercial range of the bare metal server"
  value       = data.ovh_dedicated_server.talos01.commercial_range
}

output "server_boot_id" {
  description = "Current boot ID of the server"
  value       = data.ovh_dedicated_server.talos01.boot_id
}

output "server_monitoring" {
  description = "Monitoring status of the server"
  value       = data.ovh_dedicated_server.talos01.monitoring
}
