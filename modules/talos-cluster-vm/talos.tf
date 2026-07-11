# SPDX-License-Identifier: Apache-2.0
# Copyright Maciej Sawicki

resource "talos_machine_secrets" "this" {}

locals {
  cilium_manifest = templatefile("${path.module}/templates/cilium-install.yaml.tftpl", {
    cilium_cli_image = var.cilium_cli_image
    cilium_version   = var.cilium_version
  })

  # Cluster-scope config patch: CNI=none (Cilium), CIDRs, inline Cilium
  # install, and allow scheduling on control-plane nodes (CP-only cluster).
  cluster_config_patch = yamlencode({
    cluster = {
      network = {
        cni            = { name = "none" }
        podSubnets     = [var.pod_network_cidr]
        serviceSubnets = [var.service_network_cidr]
      }
      allowSchedulingOnControlPlanes = true
      inlineManifests = [
        { name = "cilium-install", contents = local.cilium_manifest },
      ]
    }
  })

  # certSANs: every control-plane public IP + the endpoint host, so talosctl
  # and kubectl trust the cert regardless of which CP they hit.
  certsans_config_patch = yamlencode({
    machine = { certSANs = local.cp_ips }
    cluster = { apiServer = { certSANs = local.cp_ips } }
  })
}

data "talos_machine_configuration" "cp" {
  cluster_name       = var.cluster_name
  cluster_endpoint   = local.cluster_endpoint
  machine_type       = "controlplane"
  machine_secrets    = talos_machine_secrets.this.machine_secrets
  talos_version      = var.talos_version
  kubernetes_version = var.kubernetes_version
  config_patches = [
    local.cluster_config_patch,
    local.certsans_config_patch,
  ]
}

data "talos_machine_configuration" "worker" {
  count              = var.worker_count > 0 ? 1 : 0
  cluster_name       = var.cluster_name
  cluster_endpoint   = local.cluster_endpoint
  machine_type       = "worker"
  machine_secrets    = talos_machine_secrets.this.machine_secrets
  talos_version      = var.talos_version
  kubernetes_version = var.kubernetes_version
}

data "talos_client_configuration" "this" {
  cluster_name         = var.cluster_name
  client_configuration = talos_machine_secrets.this.client_configuration
  endpoints            = local.cp_ips
  nodes                = concat(local.cp_ips, local.worker_ips)
}

# Apply the control-plane config to each CP node (over its public IP).
resource "talos_machine_configuration_apply" "cp" {
  count                       = var.control_plane_count
  client_configuration        = talos_machine_secrets.this.client_configuration
  machine_configuration_input = data.talos_machine_configuration.cp.machine_configuration
  endpoint                    = local.cp_ips[count.index]
  node                        = local.cp_ips[count.index]

  depends_on = [openstack_compute_instance_v2.cp]
}

resource "talos_machine_configuration_apply" "worker" {
  count                       = var.worker_count
  client_configuration        = talos_machine_secrets.this.client_configuration
  machine_configuration_input = data.talos_machine_configuration.worker[0].machine_configuration
  endpoint                    = local.worker_ips[count.index]
  node                        = local.worker_ips[count.index]

  depends_on = [openstack_compute_instance_v2.worker]
}

# Bootstrap etcd on exactly one control-plane node (the seed). Runs once.
resource "talos_machine_bootstrap" "this" {
  client_configuration = talos_machine_secrets.this.client_configuration
  endpoint             = local.cp_ips[0]
  node                 = local.cp_ips[0]

  depends_on = [talos_machine_configuration_apply.cp]
}

resource "talos_cluster_kubeconfig" "this" {
  client_configuration = talos_machine_secrets.this.client_configuration
  endpoint             = local.cp_ips[0]
  node                 = local.cp_ips[0]

  depends_on = [talos_machine_bootstrap.this]
}
