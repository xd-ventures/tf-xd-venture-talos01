# Talos Firewall Configuration
#
# This file configures Talos ingress firewall rules to block public IP access
# and allow only Tailscale network traffic.
#
# SAFETY: Firewall is disabled by default (var.enable_firewall = false)
# Only enable after verifying Tailscale connectivity works!
#
# Verification steps before enabling:
# 1. Test Tailscale ping: tailscale ping <tailscale-ip>
# 2. Test Talos API: talosctl --endpoints <tailscale-ip> version
# 3. Test K8s API: curl -k https://<tailscale-ip>:6443/version

locals {
  # Firewall config patches - array of YAML documents for NetworkRuleConfig resources
  # These are applied as extra documents to the machine configuration
  firewall_config_patches = var.enable_firewall ? [
    # Default: Block all ingress traffic
    yamlencode({
      apiVersion = "v1alpha1"
      kind       = "NetworkDefaultActionConfig"
      ingress    = "block"
    }),

    # Allow Talos API (50000) from Tailscale only
    yamlencode({
      apiVersion = "v1alpha1"
      kind       = "NetworkRuleConfig"
      name       = "apid-tailscale"
      portSelector = {
        ports    = [50000]
        protocol = "tcp"
      }
      ingress = [
        { subnet = var.tailscale_ipv4_cidr },
        { subnet = var.tailscale_ipv6_cidr }
      ]
    }),

    # Allow Kubernetes API (6443) from Tailscale AND pod network
    # Pod network MUST be included - CoreDNS and other pods need to reach the API server!
    yamlencode({
      apiVersion = "v1alpha1"
      kind       = "NetworkRuleConfig"
      name       = "kubernetes-api"
      portSelector = {
        ports    = [6443]
        protocol = "tcp"
      }
      ingress = [
        { subnet = var.pod_network_cidr }, # Pods need API access (CoreDNS, controllers, etc.)
        { subnet = var.tailscale_ipv4_cidr },
        { subnet = var.tailscale_ipv6_cidr }
      ]
    }),

    # Allow kubelet (10250) from pod network and Tailscale
    # Pod network needed for internal cluster communication
    # Tailscale needed for kubectl exec/logs
    yamlencode({
      apiVersion = "v1alpha1"
      kind       = "NetworkRuleConfig"
      name       = "kubelet-internal"
      portSelector = {
        ports    = [10250]
        protocol = "tcp"
      }
      ingress = [
        { subnet = var.pod_network_cidr },
        { subnet = var.tailscale_ipv4_cidr },
        { subnet = var.tailscale_ipv6_cidr }
      ]
    }),

    # Allow etcd (2379-2380) from localhost only (single node cluster)
    # For multi-node clusters, add other control plane node IPs
    yamlencode({
      apiVersion = "v1alpha1"
      kind       = "NetworkRuleConfig"
      name       = "etcd-internal"
      portSelector = {
        ports    = ["2379-2380"]
        protocol = "tcp"
      }
      ingress = [
        { subnet = "127.0.0.1/32" }
      ]
    }),

    # Allow trustd (50001) from Tailscale
    # Needed for multi-node cluster communication in the future
    yamlencode({
      apiVersion = "v1alpha1"
      kind       = "NetworkRuleConfig"
      name       = "trustd-tailscale"
      portSelector = {
        ports    = [50001]
        protocol = "tcp"
      }
      ingress = [
        { subnet = var.tailscale_ipv4_cidr },
        { subnet = var.tailscale_ipv6_cidr }
      ]
    }),

    # Allow Cilium VXLAN (UDP 8472) for CNI networking
    # Cilium uses the same port as Flannel for VXLAN encapsulation
    yamlencode({
      apiVersion = "v1alpha1"
      kind       = "NetworkRuleConfig"
      name       = "cilium-vxlan"
      portSelector = {
        ports    = [8472]
        protocol = "udp"
      }
      ingress = [
        { subnet = var.pod_network_cidr },
        { subnet = var.tailscale_ipv4_cidr },
        { subnet = var.tailscale_ipv6_cidr }
      ]
    }),

    # Allow Cilium health checks (TCP 4240)
    yamlencode({
      apiVersion = "v1alpha1"
      kind       = "NetworkRuleConfig"
      name       = "cilium-health"
      portSelector = {
        ports    = [4240]
        protocol = "tcp"
      }
      ingress = [
        { subnet = var.pod_network_cidr },
        { subnet = var.tailscale_ipv4_cidr },
        { subnet = var.tailscale_ipv6_cidr }
      ]
    }),

    # Allow Hubble Relay (TCP 4244)
    # Needed for Hubble observability via Tailscale
    yamlencode({
      apiVersion = "v1alpha1"
      kind       = "NetworkRuleConfig"
      name       = "hubble-relay"
      portSelector = {
        ports    = [4244]
        protocol = "tcp"
      }
      ingress = [
        { subnet = var.tailscale_ipv4_cidr },
        { subnet = var.tailscale_ipv6_cidr }
      ]
    }),

    # NOTE: ICMP rules removed - Talos NetworkRuleConfig requires ports for portSelector
    # which doesn't apply to ICMP. Tailscale health checks may use TCP fallback.
    # TODO: Investigate if Talos has a separate mechanism for ICMP rules
  ] : []
}

# Apply firewall configuration to the cluster
# Only created when var.enable_firewall = true
#
# IMPORTANT: When Tailscale is enabled, firewall operations must use the Tailscale
# hostname/IP since the firewall blocks public IP access. The ts.net hostname
# is used which your local Tailscale MagicDNS will resolve.
resource "talos_machine_configuration_apply" "firewall" {
  count = var.enable_firewall ? 1 : 0

  depends_on = [talos_machine_bootstrap.this]

  client_configuration        = talos_machine_secrets.this.client_configuration
  machine_configuration_input = data.talos_machine_configuration.controlplane.machine_configuration

  # Use Tailscale IP when enabled (public IP is blocked by firewall)
  # Set var.tailscale_ip to the resolved IP: dig +short <hostname>.ts.net
  # This is required because the Talos provider may not have access to Tailscale's MagicDNS
  node     = local.tailscale_enabled ? local.tailscale_endpoint_ip : local.cluster_ip
  endpoint = local.tailscale_enabled ? local.tailscale_endpoint_ip : local.cluster_ip

  config_patches = local.firewall_config_patches

  # Apply without reboot - firewall rules take effect immediately
  apply_mode = "no_reboot"
}

