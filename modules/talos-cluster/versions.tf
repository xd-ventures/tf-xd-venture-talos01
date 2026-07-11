# SPDX-License-Identifier: Apache-2.0
# Copyright Maciej Sawicki

# Provider requirements for the talos-cluster module.
#
# Terraform-compatible: no OpenTofu-exclusive language features, and a
# conservative required_version floor (NOT the consumer root's >= 1.10.0,
# which is a backend-locking concern, not a module concern) — see ADR-0016.
# The module declares required_providers only; provider CONFIGURATION lives
# in the consumer root.
terraform {
  required_version = ">= 1.6.0"

  required_providers {
    ovh = {
      source  = "ovh/ovh"
      version = "~> 2.10"
    }
    talos = {
      source  = "siderolabs/talos"
      version = "~> 0.11.0"
    }
    tailscale = {
      source  = "tailscale/tailscale"
      version = "~> 0.29.0"
    }
  }
}
