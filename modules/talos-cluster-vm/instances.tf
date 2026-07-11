# SPDX-License-Identifier: Apache-2.0
# Copyright Maciej Sawicki

locals {
  cp_names     = [for i in range(var.control_plane_count) : "${var.cluster_name}-cp-${i + 1}"]
  worker_names = [for i in range(var.worker_count) : "${var.cluster_name}-w-${i + 1}"]
}

# Control-plane VMs. Booted from the Talos Glance image; machine config is
# delivered later via the Talos API (user_data left empty -> maintenance mode,
# per the spike). One public interface on Ext-Net (OVH gives a direct public
# IP; no NAT), so etcd/kubelet auto-select the node's public IP.
resource "openstack_compute_instance_v2" "cp" {
  count           = var.control_plane_count
  name            = local.cp_names[count.index]
  flavor_name     = var.flavor_name
  image_id        = var.image_id
  security_groups = [openstack_networking_secgroup_v2.cluster.name]

  network {
    name = var.external_network_name
  }

  # Talos is immutable + API-managed; no cloud-init user_data. The instance
  # boots to maintenance mode and waits for talosctl apply-config. A change
  # to image_id (i.e. a new Talos version) intentionally replaces the VM —
  # this module has no in-place OS-upgrade path, so recreation is correct.
}

resource "openstack_compute_instance_v2" "worker" {
  count           = var.worker_count
  name            = local.worker_names[count.index]
  flavor_name     = var.flavor_name
  image_id        = var.image_id
  security_groups = [openstack_networking_secgroup_v2.cluster.name]

  network {
    name = var.external_network_name
  }
}

locals {
  cp_ips     = openstack_compute_instance_v2.cp[*].access_ip_v4
  worker_ips = openstack_compute_instance_v2.worker[*].access_ip_v4
  # The cluster endpoint is the first control-plane node's public IP.
  # (A DNS/LB HA endpoint is the ADR-0017 design; a single CP IP is fine for
  # an ephemeral e2e cluster — talosconfig still fans out to all CP IPs.)
  cluster_endpoint = "https://${local.cp_ips[0]}:6443"
}
