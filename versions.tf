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
  # Configuration can be provided via environment variables:
  # - OVH_ENDPOINT (e.g., ovh-eu, ovh-ca, ovh-us)
  # - OVH_APPLICATION_KEY
  # - OVH_APPLICATION_SECRET
  # - OVH_CONSUMER_KEY
  # Or via provider block parameters (not recommended for security reasons)
  endpoint = var.ovh_endpoint
}

provider "talos" {
  # No authentication required for basic usage
  # The provider is used to generate configurations and fetch image factory URLs
}
