# SPDX-License-Identifier: Apache-2.0
# Copyright Maciej Sawicki

# Security group for the cluster VMs. Node-to-node traffic (etcd, kubelet,
# Cilium, Talos apid) is allowed within the group; the Talos and Kubernetes
# APIs are reachable from allowed_api_cidrs (operator/CI) for bootstrap and
# health checks. All VMs share one public interface (OVH Ext-Net).
resource "openstack_networking_secgroup_v2" "cluster" {
  name        = "${var.cluster_name}-cluster"
  description = "Talos cluster ${var.cluster_name} — node mesh + operator API access"
}

# Node-to-node: allow everything within the group (etcd 2379-2380, kubelet
# 10250, Cilium VXLAN 8472, Talos apid/trustd 50000-50001, k8s 6443, etc.).
resource "openstack_networking_secgroup_rule_v2" "node_tcp" {
  direction         = "ingress"
  ethertype         = "IPv4"
  protocol          = "tcp"
  remote_group_id   = openstack_networking_secgroup_v2.cluster.id
  security_group_id = openstack_networking_secgroup_v2.cluster.id
}

resource "openstack_networking_secgroup_rule_v2" "node_udp" {
  direction         = "ingress"
  ethertype         = "IPv4"
  protocol          = "udp"
  remote_group_id   = openstack_networking_secgroup_v2.cluster.id
  security_group_id = openstack_networking_secgroup_v2.cluster.id
}

# Operator/CI access to the Talos API (50000) and Kubernetes API (6443).
resource "openstack_networking_secgroup_rule_v2" "talos_api" {
  for_each          = toset(var.allowed_api_cidrs)
  direction         = "ingress"
  ethertype         = "IPv4"
  protocol          = "tcp"
  port_range_min    = 50000
  port_range_max    = 50001
  remote_ip_prefix  = each.value
  security_group_id = openstack_networking_secgroup_v2.cluster.id
}

resource "openstack_networking_secgroup_rule_v2" "k8s_api" {
  for_each          = toset(var.allowed_api_cidrs)
  direction         = "ingress"
  ethertype         = "IPv4"
  protocol          = "tcp"
  port_range_min    = 6443
  port_range_max    = 6443
  remote_ip_prefix  = each.value
  security_group_id = openstack_networking_secgroup_v2.cluster.id
}

# Allow ICMP from allowed CIDRs (ping / health).
resource "openstack_networking_secgroup_rule_v2" "icmp" {
  for_each          = toset(var.allowed_api_cidrs)
  direction         = "ingress"
  ethertype         = "IPv4"
  protocol          = "icmp"
  remote_ip_prefix  = each.value
  security_group_id = openstack_networking_secgroup_v2.cluster.id
}
