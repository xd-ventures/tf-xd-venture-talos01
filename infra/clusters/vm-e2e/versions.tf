# SPDX-License-Identifier: Apache-2.0
# Copyright Maciej Sawicki

# Second cluster: 3 control-plane VMs on OVH Public Cloud, consuming the
# talos-cluster-vm module. Separate state from the production single-node
# cluster (local backend for this ephemeral e2e instance; a dedicated remote
# state bucket is #329 work). Applying/destroying this NEVER touches the
# production cluster — different project, different state, different module.
terraform {
  required_version = ">= 1.6.0"

  # Local state: this is a disposable e2e cluster. Do not use for anything
  # data-bearing. State is gitignored.
  backend "local" {}

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

# OpenStack provider reads OS_* env vars (source the e2e openrc).
provider "openstack" {}

provider "talos" {}
