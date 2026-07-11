# SPDX-License-Identifier: Apache-2.0
# Copyright Maciej Sawicki

# xd-ventures single-node Talos cluster on OVH bare metal.
#
# This root consumes the talos-cluster module (the extracted cluster
# definition) and owns the consumer-level concerns: state backend, provider
# configuration, ArgoCD, Shodan monitoring, and etcd-backup storage.
#
# The module renders byte-identically to the pre-extraction root config for
# this single-node baremetal input (verified: the extraction plan is
# moves-only, ADR-0016 decision 3). The moved{} blocks below migrate every
# resource's state address into the module without touching real infra.

module "talos" {
  source = "../modules/talos-cluster"

  ovh_subsidiary              = var.ovh_subsidiary
  monitoring_enabled          = var.monitoring_enabled
  server_state                = var.server_state
  talos_version               = var.talos_version
  kubernetes_version          = var.kubernetes_version
  upgrade_mode                = var.upgrade_mode
  cluster_name                = var.cluster_name
  cluster_endpoint            = var.cluster_endpoint
  talos_endpoints             = var.talos_endpoints
  talos_nodes                 = var.talos_nodes
  talos_extensions            = var.talos_extensions
  architecture                = var.architecture
  use_raw_image               = var.use_raw_image
  extra_kernel_args           = var.extra_kernel_args
  cilium_cli_image            = var.cilium_cli_image
  cilium_version              = var.cilium_version
  zfs_pool_job_image          = var.zfs_pool_job_image
  tailscale_hostname          = var.tailscale_hostname
  tailscale_tailnet           = var.tailscale_tailnet
  tailscale_ip                = var.tailscale_ip
  tailscale_device_lookup     = var.tailscale_device_lookup
  tailscale_extra_args        = var.tailscale_extra_args
  tailscale_tags              = var.tailscale_tags
  enable_firewall             = var.enable_firewall
  pod_network_cidr            = var.pod_network_cidr
  service_network_cidr        = var.service_network_cidr
  tailscale_ipv4_cidr         = var.tailscale_ipv4_cidr
  tailscale_ipv6_cidr         = var.tailscale_ipv6_cidr
  zfs_pool_enabled            = var.zfs_pool_enabled
  zfs_pool_name               = var.zfs_pool_name
  zfs_pool_mount_point        = var.zfs_pool_mount_point
  zfs_pool_disks              = var.zfs_pool_disks
  ephemeral_max_size          = var.ephemeral_max_size
  talos_backup_enabled        = var.talos_backup_enabled
  talos_backup_age_public_key = var.talos_backup_age_public_key
  talos_backup_s3_bucket      = var.talos_backup_s3_bucket
  talos_backup_s3_region      = var.talos_backup_s3_region
  talos_backup_schedule       = var.talos_backup_schedule
  ovh_cloud_project_id        = var.ovh_cloud_project_id
  talos_backup_image          = var.talos_backup_image
  talos_backup_verify_image   = var.talos_backup_verify_image
}

# --- State address migration (root -> module.talos). Pure state operations,
#     no API calls: applying these does NOT touch the running machine. ---
moved {
  from = ovh_dedicated_server.talos01
  to   = module.talos.ovh_dedicated_server.talos01
}

moved {
  from = ovh_dedicated_server_reinstall_task.talos
  to   = module.talos.ovh_dedicated_server_reinstall_task.talos
}

moved {
  from = talos_machine_secrets.this
  to   = module.talos.talos_machine_secrets.this
}

moved {
  from = talos_image_factory_schematic.this
  to   = module.talos.talos_image_factory_schematic.this
}

moved {
  from = talos_machine_bootstrap.this
  to   = module.talos.talos_machine_bootstrap.this
}

moved {
  from = talos_machine_configuration_apply.controlplane
  to   = module.talos.talos_machine_configuration_apply.controlplane
}

moved {
  from = terraform_data.talos_upgrade
  to   = module.talos.terraform_data.talos_upgrade
}

moved {
  from = talos_cluster_kubeconfig.this
  to   = module.talos.talos_cluster_kubeconfig.this
}

moved {
  from = terraform_data.tailscale_device_cleanup
  to   = module.talos.terraform_data.tailscale_device_cleanup
}

moved {
  from = tailscale_tailnet_key.talos
  to   = module.talos.tailscale_tailnet_key.talos
}

moved {
  from = terraform_data.reinstall_trigger
  to   = module.talos.terraform_data.reinstall_trigger
}
