terraform {
  required_version = ">= 1.6.0"

  required_providers {
    ovh = {
      source  = "ovh/ovh"
      version = "~> 2.0"
    }
    talos = {
      source  = "siderolabs/talos"
      version = "~> 0.6"
    }
  }
}

provider "ovh" {
  # Configuration via environment variables:
  # - OVH_ENDPOINT
  # - OVH_APPLICATION_KEY
  # - OVH_APPLICATION_SECRET
  # - OVH_CONSUMER_KEY
  endpoint = var.ovh_endpoint
}

provider "talos" {
  # No authentication required for basic usage
}
