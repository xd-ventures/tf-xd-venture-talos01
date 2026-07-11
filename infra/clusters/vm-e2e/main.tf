# SPDX-License-Identifier: Apache-2.0
# Copyright Maciej Sawicki

module "cluster" {
  source = "../../../modules/talos-cluster-vm"

  cluster_name        = var.cluster_name
  control_plane_count = var.control_plane_count
  worker_count        = var.worker_count
  flavor_name         = var.flavor_name
  image_id            = var.image_id
  talos_version       = var.talos_version
  kubernetes_version  = var.kubernetes_version
  allowed_api_cidrs   = var.allowed_api_cidrs
}
