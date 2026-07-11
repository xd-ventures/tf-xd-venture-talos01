# SPDX-License-Identifier: Apache-2.0
# Copyright Maciej Sawicki

output "control_plane_ips" {
  description = "Public IPs of the control-plane VMs."
  value       = local.cp_ips
}

output "worker_ips" {
  description = "Public IPs of the worker VMs."
  value       = local.worker_ips
}

output "cluster_endpoint" {
  description = "Kubernetes API endpoint (first control-plane IP)."
  value       = local.cluster_endpoint
}

output "kubeconfig" {
  description = "Kubeconfig for the cluster."
  value       = talos_cluster_kubeconfig.this.kubeconfig_raw
  sensitive   = true
}

output "talosconfig" {
  description = "Talos client configuration."
  value       = data.talos_client_configuration.this.talos_config
  sensitive   = true
}
