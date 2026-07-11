# SPDX-License-Identifier: Apache-2.0
# Copyright Maciej Sawicki

# Provider requirements for the talos-cluster-vm module — a multi-node Talos
# cluster on OpenStack VMs (OVH Public Cloud). Provider CONFIGURATION lives in
# the consumer root; the module declares required_providers only (ADR-0016).
#
# This is the "node-ovh-publiccloud + multi-node" path. It is a SEPARATE
# module from talos-cluster (single-node baremetal) on purpose: unifying them
# into talos-core + per-provider adapters is tracked in #322 and must be its
# own zero-diff exercise on the production single node.
terraform {
  required_version = ">= 1.6.0"

  required_providers {
    openstack = {
      source  = "terraform-provider-openstack/openstack"
      version = "~> 3.0"
    }
    talos = {
      source  = "siderolabs/talos"
      version = "~> 0.11.0"
    }
  }
}
