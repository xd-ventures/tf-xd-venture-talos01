terraform {
  required_version = ">= 1.6.0"

  required_providers {
    ovh = {
      source  = "ovh/ovh"
      version = "~> 2.0"
    }
    talos = {
      source  = "siderolabs/talos"
      version = "~> 0.10.0"
    }
    tailscale = {
      source  = "tailscale/tailscale"
      version = "~> 0.27.0"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 3.0"
    }
    helm = {
      source  = "hashicorp/helm"
      version = "~> 3.0"
    }
    argocd = {
      source  = "argoproj-labs/argocd"
      version = "~> 7.0"
    }
    shodan = {
      source  = "registry.terraform.io/AdconnectDevOps/shodan"
      version = "~> 0.1"
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

# Shodan provider configuration
# Set api_key via TF_VAR_shodan_api_key in .env or -var flag
provider "shodan" {
  api_key = var.shodan_api_key
}

# Kubernetes provider configuration
# Uses kubeconfig from Talos cluster after bootstrap
provider "kubernetes" {
  host                   = local.argocd_enabled ? local.k8s_host : null
  cluster_ca_certificate = local.argocd_enabled ? local.k8s_cluster_ca_certificate : null
  client_certificate     = local.argocd_enabled ? local.k8s_client_certificate : null
  client_key             = local.argocd_enabled ? local.k8s_client_key : null
}

# Helm provider configuration
# Uses same authentication as kubernetes provider
provider "helm" {
  kubernetes = {
    host                   = local.argocd_enabled ? local.k8s_host : null
    cluster_ca_certificate = local.argocd_enabled ? local.k8s_cluster_ca_certificate : null
    client_certificate     = local.argocd_enabled ? local.k8s_client_certificate : null
    client_key             = local.argocd_enabled ? local.k8s_client_key : null
  }
}

# ArgoCD provider configuration
# Connects to ArgoCD server after installation via Helm
# Uses Kubernetes port-forward to access ArgoCD server from local machine
provider "argocd" {
  # Use port forwarding via kubernetes provider (creates ephemeral port-forward)
  # This is required because we can't resolve argocd-server.argocd.svc.cluster.local from local machine
  port_forward_with_namespace = "argocd"
  insecure                    = true # Server runs in insecure mode behind Tailscale

  # Use admin credentials from the initial secret
  username = "admin"
  password = var.argocd_enabled ? data.kubernetes_secret_v1.argocd_initial_admin[0].data.password : ""

  # Kubernetes authentication for port-forward
  kubernetes {
    host                   = local.argocd_enabled ? local.k8s_host : null
    cluster_ca_certificate = local.argocd_enabled ? local.k8s_cluster_ca_certificate : null
    client_certificate     = local.argocd_enabled ? local.k8s_client_certificate : null
    client_key             = local.argocd_enabled ? local.k8s_client_key : null
  }
}
