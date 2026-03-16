# SPDX-License-Identifier: Apache-2.0
# Copyright Maciej Sawicki

# Talos Firewall Configuration
#
# Bakes NetworkDefaultActionConfig + NetworkRuleConfig into the config drive
# so the firewall is active from first boot — BEFORE Talos API starts listening.
#
# When enabled, ALL ingress is blocked except:
# - Tailscale (100.64.0.0/10, fd7a:115c:a1e0::/48)
# - Localhost (127.0.0.0/8) for internal cluster communication
# - Pod and Service CIDRs for Kubernetes networking
#
# Tailscale uses outbound connections only (UDP 41641 direct, HTTPS 443 DERP),
# so ingress BLOCK does not affect Tailscale connectivity.
#
# Recovery when Tailscale is down: OVH iKVM console or rescue mode.

locals {
  # Firewall config patches - array of YAML documents baked into the config drive.
  # Applied by machined BEFORE any service binds (no race condition).
  firewall_config_patches = var.enable_firewall ? [
    # Default: Block all ingress traffic
    yamlencode({
      apiVersion = "v1alpha1"
      kind       = "NetworkDefaultActionConfig"
      ingress    = "block"
    }),

    # Allow Talos API (50000) from Tailscale and localhost
    yamlencode({
      apiVersion = "v1alpha1"
      kind       = "NetworkRuleConfig"
      name       = "talos-api"
      portSelector = {
        ports    = [50000]
        protocol = "tcp"
      }
      ingress = [
        { subnet = "127.0.0.0/8" },
        { subnet = var.tailscale_ipv4_cidr },
        { subnet = var.tailscale_ipv6_cidr },
      ]
    }),

    # Allow trustd (50001) from Tailscale and localhost
    yamlencode({
      apiVersion = "v1alpha1"
      kind       = "NetworkRuleConfig"
      name       = "trustd"
      portSelector = {
        ports    = [50001]
        protocol = "tcp"
      }
      ingress = [
        { subnet = "127.0.0.0/8" },
        { subnet = var.tailscale_ipv4_cidr },
        { subnet = var.tailscale_ipv6_cidr },
      ]
    }),

    # Allow Kubernetes API (6443) from Tailscale, localhost, pods, and services
    # Pods and services MUST be included — CoreDNS, controllers, and ClusterIP traffic
    yamlencode({
      apiVersion = "v1alpha1"
      kind       = "NetworkRuleConfig"
      name       = "kubernetes-api"
      portSelector = {
        ports    = [6443]
        protocol = "tcp"
      }
      ingress = [
        { subnet = "127.0.0.0/8" },
        { subnet = var.pod_network_cidr },
        { subnet = var.service_network_cidr },
        { subnet = var.tailscale_ipv4_cidr },
        { subnet = var.tailscale_ipv6_cidr },
      ]
    }),

    # Allow kubelet (10250) from localhost, pods, and Tailscale
    # Tailscale needed for kubectl exec/logs
    yamlencode({
      apiVersion = "v1alpha1"
      kind       = "NetworkRuleConfig"
      name       = "kubelet"
      portSelector = {
        ports    = [10250]
        protocol = "tcp"
      }
      ingress = [
        { subnet = "127.0.0.0/8" },
        { subnet = var.pod_network_cidr },
        { subnet = var.tailscale_ipv4_cidr },
        { subnet = var.tailscale_ipv6_cidr },
      ]
    }),

    # Allow etcd (2379-2380) from localhost only (single node cluster)
    yamlencode({
      apiVersion = "v1alpha1"
      kind       = "NetworkRuleConfig"
      name       = "etcd"
      portSelector = {
        ports    = ["2379-2380"]
        protocol = "tcp"
      }
      ingress = [
        { subnet = "127.0.0.0/8" },
      ]
    }),

    # Allow Cilium VXLAN (UDP 8472) from localhost and pods
    # Single-node: VXLAN traffic is local. For multi-node, add node subnet CIDRs
    # since VXLAN outer headers use node IPs, not pod IPs.
    yamlencode({
      apiVersion = "v1alpha1"
      kind       = "NetworkRuleConfig"
      name       = "cilium-vxlan"
      portSelector = {
        ports    = [8472]
        protocol = "udp"
      }
      ingress = [
        { subnet = "127.0.0.0/8" },
        { subnet = var.pod_network_cidr },
      ]
    }),

    # Allow Cilium health checks (TCP 4240) from localhost and pods
    yamlencode({
      apiVersion = "v1alpha1"
      kind       = "NetworkRuleConfig"
      name       = "cilium-health"
      portSelector = {
        ports    = [4240]
        protocol = "tcp"
      }
      ingress = [
        { subnet = "127.0.0.0/8" },
        { subnet = var.pod_network_cidr },
      ]
    }),

    # Allow Hubble Relay (TCP 4244) from Tailscale and localhost
    yamlencode({
      apiVersion = "v1alpha1"
      kind       = "NetworkRuleConfig"
      name       = "hubble-relay"
      portSelector = {
        ports    = [4244]
        protocol = "tcp"
      }
      ingress = [
        { subnet = "127.0.0.0/8" },
        { subnet = var.tailscale_ipv4_cidr },
        { subnet = var.tailscale_ipv6_cidr },
      ]
    }),

    # Allow Hubble Peer (TCP 4245) from localhost and pods
    # Cilium agent-to-agent communication for Hubble observability
    yamlencode({
      apiVersion = "v1alpha1"
      kind       = "NetworkRuleConfig"
      name       = "hubble-peer"
      portSelector = {
        ports    = [4245]
        protocol = "tcp"
      }
      ingress = [
        { subnet = "127.0.0.0/8" },
        { subnet = var.pod_network_cidr },
      ]
    }),
  ] : []
}
