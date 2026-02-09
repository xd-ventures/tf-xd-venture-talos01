# ArgoCD Installation and Configuration
#
# This file automates the ArgoCD Getting Started guide:
# - Step 1: Install ArgoCD via Helm
# - Step 3: Access via ClusterIP (Tailscale-only)
# - Step 4: Initial admin password retrieval
# - Step 6-7: Create and sync sample application

# Local values for Kubernetes/Helm provider authentication
# These are extracted from the Talos kubeconfig after cluster bootstrap
locals {
  # ArgoCD enabled flag (used by providers and resources)
  argocd_enabled = var.argocd_enabled

  # Parse kubeconfig YAML to extract authentication details
  # Only parse when ArgoCD is enabled to avoid errors during initial bootstrap
  kubeconfig_parsed = local.argocd_enabled ? yamldecode(talos_cluster_kubeconfig.this.kubeconfig_raw) : null

  # Kubernetes API server URL
  # When Tailscale is enabled, use the ts.net hostname for secure access
  k8s_host = local.argocd_enabled ? (
    local.tailscale_enabled
    ? "https://${local.tailscale_ts_net_hostname}:6443"
    : local.kubeconfig_parsed.clusters[0].cluster.server
  ) : null

  # Cluster CA certificate (base64 decoded)
  k8s_cluster_ca_certificate = local.argocd_enabled ? base64decode(
    local.kubeconfig_parsed.clusters[0].cluster["certificate-authority-data"]
  ) : null

  # Client certificate for authentication (base64 decoded)
  k8s_client_certificate = local.argocd_enabled ? base64decode(
    local.kubeconfig_parsed.users[0].user["client-certificate-data"]
  ) : null

  # Client key for authentication (base64 decoded)
  k8s_client_key = local.argocd_enabled ? base64decode(
    local.kubeconfig_parsed.users[0].user["client-key-data"]
  ) : null
}

# ArgoCD Helm Release
# Deploys ArgoCD using the official Helm chart
resource "helm_release" "argocd" {
  count = var.argocd_enabled ? 1 : 0

  name             = "argocd"
  repository       = "https://argoproj.github.io/argo-helm"
  chart            = "argo-cd"
  version          = var.argocd_chart_version
  namespace        = "argocd"
  create_namespace = true

  # Wait for all resources to be ready
  wait          = true
  wait_for_jobs = true
  timeout       = 600

  # Helm values for Tailscale-only access configuration
  values = [
    yamlencode({
      # Global settings
      global = {
        # Use cluster domain for internal communication
        domain = "argocd.${var.cluster_name}.local"

        # Tolerate control-plane taint for single-node clusters
        # This allows ArgoCD to be scheduled on control-plane nodes
        tolerations = [
          {
            key      = "node-role.kubernetes.io/control-plane"
            operator = "Exists"
            effect   = "NoSchedule"
          }
        ]
      }

      # Server configuration
      server = {
        # ClusterIP service - access via kubectl port-forward only
        service = {
          type = "ClusterIP"
        }

        # Enable insecure mode for port-forward access (TLS termination not needed)
        # This allows accessing ArgoCD without dealing with self-signed certs
        extraArgs = var.argocd_server_insecure ? ["--insecure"] : []
      }

      # Redis configuration (password auth is enabled by default)
      redis = {
        enabled = true
      }

      # Configs
      configs = {
        params = {
          # Run server in insecure mode (no TLS) when enabled
          # Safe because access is only via Tailscale + port-forward
          "server.insecure" = var.argocd_server_insecure
        }
      }
    })
  ]

  depends_on = [
    talos_cluster_kubeconfig.this,
  ]
}

# Data source to retrieve the initial admin password
# ArgoCD generates this automatically and stores it in a secret
data "kubernetes_secret" "argocd_initial_admin" {
  count = var.argocd_enabled ? 1 : 0

  metadata {
    name      = "argocd-initial-admin-secret"
    namespace = "argocd"
  }

  depends_on = [
    helm_release.argocd,
  ]
}

# Sample ArgoCD Application - Guestbook
# This demonstrates ArgoCD's GitOps workflow using the official example app
resource "argocd_application" "guestbook" {
  count = var.argocd_enabled && var.argocd_deploy_guestbook ? 1 : 0

  metadata {
    name      = "guestbook"
    namespace = "argocd"
    labels = {
      "app.kubernetes.io/managed-by" = "terraform"
      "example"                      = "true"
    }
  }

  # Wait for application to sync
  wait = true

  spec {
    # Use default project
    project = "default"

    # Source repository - ArgoCD example apps
    source {
      repo_url        = "https://github.com/argoproj/argocd-example-apps.git"
      path            = "guestbook"
      target_revision = "HEAD"
    }

    # Deploy to the same cluster (in-cluster)
    destination {
      server    = "https://kubernetes.default.svc"
      namespace = "default"
    }

    # Sync policy - automated sync with self-healing
    sync_policy {
      automated {
        prune       = true # Remove resources not in Git
        self_heal   = true # Revert manual changes
        allow_empty = false
      }

      sync_options = [
        "CreateNamespace=true",
        "PruneLast=true",
      ]

      retry {
        limit = "5"
        backoff {
          duration     = "5s"
          max_duration = "3m"
          factor       = "2"
        }
      }
    }
  }

  depends_on = [
    helm_release.argocd,
    data.kubernetes_secret.argocd_initial_admin,
  ]
}

