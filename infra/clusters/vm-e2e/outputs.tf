# SPDX-License-Identifier: Apache-2.0
# Copyright Maciej Sawicki

output "control_plane_ips" {
  value = module.cluster.control_plane_ips
}
output "cluster_endpoint" {
  value = module.cluster.cluster_endpoint
}
output "kubeconfig" {
  value     = module.cluster.kubeconfig
  sensitive = true
}
output "talosconfig" {
  value     = module.cluster.talosconfig
  sensitive = true
}
