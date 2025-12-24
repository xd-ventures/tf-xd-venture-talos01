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
