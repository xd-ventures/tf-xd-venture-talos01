# SPDX-License-Identifier: Apache-2.0
# Copyright Maciej Sawicki

# Cluster Health Status
output "cluster_health_status" {
  description = "Cluster health check status (only available when Tailscale is disabled)"
  value       = length(data.talos_cluster_health.this) > 0 ? "healthy" : "skipped (Tailscale enabled - verify manually)"
}

# Server Outputs
output "server_id" {
  description = "The service name/ID of the bare metal server"
  value       = ovh_dedicated_server.talos01.service_name
}

output "server_name" {
  description = "The name of the bare metal server"
  value       = ovh_dedicated_server.talos01.display_name
}

output "server_state_actual" {
  description = "The current state reported by OVH (may differ from var.server_state, the desired state)"
  value       = ovh_dedicated_server.talos01.state
}

output "server_ip" {
  description = "The IP address of the bare metal server"
  value       = ovh_dedicated_server.talos01.ip
}

# Talos Configuration Outputs
output "talos_schematic_id" {
  description = "The Talos image factory schematic ID"
  value       = talos_image_factory_schematic.this.id
}

output "talos_image_url" {
  description = "The Talos image URL being deployed"
  value       = local.image_url
}

output "talos_installer_image" {
  description = "The Talos installer image for upgrades"
  value       = "factory.talos.dev/installer/${talos_image_factory_schematic.this.id}:${var.talos_version}"
}

output "installation_image_url" {
  description = "The image URL being used for installation"
  value       = local.image_url
}

output "installation_image_type" {
  description = "The image type being used (qcow2 or raw)"
  value       = local.image_type
}

output "efi_bootloader_path" {
  description = "The EFI bootloader path being used"
  value       = local.efi_bootloader_path_grub
}

# Named *_actual to avoid shadowing var.cluster_endpoint, which holds the
# pre-resolution template (possibly with the <server-ip> placeholder).
output "cluster_endpoint_actual" {
  description = "Kubernetes API endpoint URL (actual endpoint used in cluster config)"
  value       = local.actual_cluster_endpoint
}

output "cluster_endpoint_public" {
  description = "Kubernetes API endpoint via public IP (for initial bootstrap)"
  value       = local.public_cluster_endpoint
}

# Sensitive outputs - use with care
output "talos_machine_config" {
  description = "Base64 encoded machine configuration (for manual apply if needed)"
  value       = base64encode(data.talos_machine_configuration.controlplane.machine_configuration)
  sensitive   = true
}

output "talosconfig" {
  description = "Talos client configuration for talosctl - ready to use YAML file"
  # When firewall is enabled, endpoints use the Tailscale IP (public IP is blocked).
  # When firewall is disabled, endpoints use the public IP.
  value     = data.talos_client_configuration.this.talos_config
  sensitive = true
}

output "talosconfig_save_command" {
  description = "Command to save talosconfig to file"
  value       = "tofu output -raw talosconfig > talosconfig"
}

output "bootstrap_completed" {
  description = "Indicates when the Talos cluster bootstrap was completed"
  value       = talos_machine_bootstrap.this.id
}

# Kubernetes access
# NOTE: When Tailscale is enabled, we replace the public IP in the kubeconfig
# with the ts.net hostname. The talos_cluster_kubeconfig resource uses the
# connection endpoint (public IP) as the server URL, but we want users to
# connect via Tailscale for security.
output "kubeconfig" {
  description = "Kubernetes admin configuration for kubectl - ready to use YAML file"
  # kubeconfig_raw's server URL is the public IP; rewrite it to the stable
  # ts.net hostname when Tailscale is enabled (verified live: the replace
  # matches — see #252 discussion).
  value = local.tailscale_enabled ? replace(
    talos_cluster_kubeconfig.this.kubeconfig_raw,
    "https://${local.cluster_ip}:6443",
    "https://${local.tailscale_ts_net_hostname}:6443"
  ) : talos_cluster_kubeconfig.this.kubeconfig_raw
  sensitive = true
}

output "kubeconfig_save_command" {
  description = "Command to save kubeconfig to file"
  value       = "tofu output -raw kubeconfig > kubeconfig"
}

# WARNING: Bypasses the Tailscale security model. Only functional while the
# firewall is DISABLED — with the firewall enabled, 6443 is blocked on the
# public IP and no kubeconfig helps (use iKVM/rescue mode instead; see
# docs/DISASTER_RECOVERY.md). kubeconfig_raw's server URL is already the
# public IP (verified live, #252 — the review claim that it pointed at
# ts.net was incorrect), so it is returned as-is.
output "kubeconfig_public_ip" {
  description = "Kubeconfig pointing at the public IP for emergency access while the firewall is disabled. WARNING: bypasses Tailscale."
  value       = talos_cluster_kubeconfig.this.kubeconfig_raw
  sensitive   = true
}

# Tailscale outputs (only shown when Tailscale is configured)
output "tailscale_enabled" {
  description = "Whether Tailscale is enabled for this cluster"
  value       = local.tailscale_enabled
}

# Named tailscale_fqdn to avoid shadowing var.tailscale_hostname (the short
# machine name); this is the full <hostname>.<tailnet>.ts.net form.
output "tailscale_fqdn" {
  description = "Full Tailscale hostname (ts.net) for accessing the cluster. Null when Tailscale is not configured."
  value       = local.tailscale_ts_net_hostname != "" ? local.tailscale_ts_net_hostname : null
}

# Tailscale device outputs (from the device lookup data source; null when
# lookup is disabled or Tailscale is not configured). Moved here from
# tailscale.tf so all outputs live in outputs.tf.
output "tailscale_device_id" {
  description = "Tailscale device ID (from data source lookup)"
  value       = length(data.tailscale_device.talos_node) > 0 ? data.tailscale_device.talos_node[0].id : null
}

output "tailscale_device_ip" {
  description = "Tailscale device IP (from data source lookup, always current)"
  value       = length(data.tailscale_device.talos_node) > 0 ? data.tailscale_device.talos_node[0].addresses[0] : null
}

output "tailscale_access_info" {
  description = "Information about accessing the cluster via Tailscale"
  value = local.tailscale_enabled ? {
    ts_net_hostname    = local.tailscale_ts_net_hostname
    talos_api_endpoint = "https://${local.tailscale_ts_net_hostname}:50000"
    k8s_api_endpoint   = "https://${local.tailscale_ts_net_hostname}:6443"
    security_note      = var.enable_firewall ? "Firewall ENABLED - Public IP access blocked. Access via Tailscale only." : "Cluster configured for Tailscale access. Set enable_firewall=true to block public IP."
    # NOTE: talosctl's gRPC resolver doesn't support MagicDNS, so we resolve the IP first
    talosctl_command = "TSIP=$(dig +short ${local.tailscale_ts_net_hostname}) && talosctl --endpoints $TSIP --nodes $TSIP"
    } : {
    ts_net_hostname    = null
    talos_api_endpoint = "https://${local.cluster_ip}:50000"
    k8s_api_endpoint   = "https://${local.cluster_ip}:6443"
    security_note      = "APIs accessible on public IP. Consider enabling Tailscale for secure access."
    talosctl_command   = "talosctl --endpoints ${local.cluster_ip} --nodes ${local.cluster_ip}"
  }
}

output "firewall_warning" {
  description = "Warning displayed when firewall is disabled"
  value       = !var.enable_firewall ? "WARNING: Firewall is DISABLED — Talos API (50000) is unauthenticated before bootstrap. Enable with: enable_firewall = true (triggers reinstall)" : null
}

# Firewall outputs
output "firewall_enabled" {
  description = "Whether the Talos firewall is enabled (blocking public IP access)"
  value       = var.enable_firewall
}

output "firewall_status" {
  description = "Firewall configuration status and details. Note: allowed_networks is the union of networks that can reach at least one service; per-port rules still apply."
  value = var.enable_firewall ? {
    status           = "ENABLED - Baked into config drive, active from first boot"
    allowed_networks = ["127.0.0.0/8", var.pod_network_cidr, var.service_network_cidr, var.tailscale_ipv4_cidr, var.tailscale_ipv6_cidr]
    blocked_ports    = ["50000 (Talos API)", "6443 (K8s API)", "10250 (kubelet)", "2379-2380 (etcd)"]
    access_via       = "Tailscale only (bootstrap uses Tailscale IP)"
    emergency_access = "OVH iKVM console or rescue mode. Or reinstall with enable_firewall=false."
    } : {
    status           = "DISABLED - Public IP access allowed"
    allowed_networks = ["0.0.0.0/0", "::/0"]
    blocked_ports    = []
    access_via       = "Public IP and Tailscale"
    emergency_access = "N/A - firewall disabled"
  }
}

# Verification commands (dynamically generated with actual values)
output "firewall_verification_commands" {
  description = "Commands to verify firewall is working (after deploy with enable_firewall=true). Command keys are null until Tailscale is configured and the firewall is enabled — see status."
  value = local.tailscale_enabled && var.enable_firewall ? {
    status               = "Firewall enabled — run each command below to verify"
    test_public_blocked  = "curl -k --connect-timeout 5 https://${local.cluster_ip}:6443/version  # Should FAIL/timeout"
    test_tailscale_works = "curl -k https://$(dig +short ${local.tailscale_ts_net_hostname}):6443/version  # Should SUCCEED"
    test_talos_api       = "TSIP=$(dig +short ${local.tailscale_ts_net_hostname}) && talosctl --endpoints $TSIP --nodes $TSIP version"
    recovery_note        = "If locked out: use OVH iKVM console or rescue mode to edit config drive"
    } : {
    status = local.tailscale_enabled ? (
      "Firewall disabled. Set enable_firewall = true and run tofu apply to enable (triggers reinstall)."
      ) : (
      "Tailscale not configured. Set tailscale_hostname and tailscale_tailnet first."
    )
    test_public_blocked  = null
    test_tailscale_works = null
    test_talos_api       = null
    recovery_note        = null
  }
}

# ArgoCD Outputs

output "argocd_enabled" {
  description = "Whether ArgoCD is deployed to the cluster"
  value       = var.argocd_enabled
}

output "argocd_admin_password" {
  description = "Initial admin password for ArgoCD (auto-generated). Delete argocd-initial-admin-secret after changing. Null when ArgoCD is disabled or the admin account has been disabled (argocd_disable_admin)."
  value       = var.argocd_enabled && !var.argocd_disable_admin ? data.kubernetes_secret_v1.argocd_initial_admin[0].data.password : null
  sensitive   = true
}

output "argocd_server_url" {
  description = "ArgoCD server URL (internal cluster address). Null when ArgoCD is disabled."
  value       = var.argocd_enabled ? "https://argocd-server.argocd.svc.cluster.local" : null
}

output "argocd_access_info" {
  description = "Information for accessing ArgoCD UI and API"
  value = var.argocd_enabled ? {
    status = "ArgoCD deployed"

    # Access instructions
    port_forward_command = "kubectl port-forward svc/argocd-server -n argocd 8080:443"
    ui_url               = var.argocd_server_insecure ? "http://localhost:8080" : "https://localhost:8080"
    username             = "admin"
    get_password_command = "tofu output -raw argocd_admin_password"

    # CLI login (after port-forward)
    cli_login_command = var.argocd_server_insecure ? "argocd login localhost:8080 --insecure --username admin --password $(tofu output -raw argocd_admin_password)" : "argocd login localhost:8080 --username admin --password $(tofu output -raw argocd_admin_password)"

    # Security notes
    security_note = "ArgoCD is only accessible via kubectl port-forward (Tailscale required). No external exposure."

    # Post-deploy hardening
    password_rotation = "1) argocd account update-password  2) kubectl delete secret argocd-initial-admin-secret -n argocd  3) Set argocd_disable_admin = true and re-apply"

    # Helm release info
    helm_chart_version = var.argocd_chart_version
    namespace          = "argocd"
    } : {
    status               = "ArgoCD not enabled. Set argocd_enabled = true to deploy."
    port_forward_command = null
    ui_url               = null
    username             = null
    get_password_command = null
    cli_login_command    = null
    security_note        = null
    password_rotation    = null
    helm_chart_version   = null
    namespace            = null
  }
}

# Shodan Monitoring Outputs

output "shodan_monitoring_info" {
  description = "Shodan network monitoring status and details"
  value = var.shodan_enabled ? {
    status       = "ENABLED - Monitoring server public IP for accidental exposure"
    alert_id     = shodan_alert.server[0].id
    monitored_ip = "${ovh_dedicated_server.talos01.ip}/32"
    triggers     = var.shodan_triggers
    dashboard    = "https://monitor.shodan.io/dashboard"
    } : {
    status       = "DISABLED - Set shodan_enabled = true and provide SHODAN_API_KEY to enable"
    alert_id     = null
    monitored_ip = null
    triggers     = []
    dashboard    = null
  }
}

# ZFS Pool Outputs

output "zfs_pool_info" {
  description = "ZFS pool configuration status and details"
  value = var.zfs_pool_enabled ? {
    status      = "ENABLED - ZFS pool will be created via inline manifest Job"
    pool_name   = var.zfs_pool_name
    mount_point = var.zfs_pool_mount_point
    disks       = [for d in var.zfs_pool_disks : "${d.device}p${d.partition}"]
    topology    = "mirror"
    verify      = "kubectl logs -n kube-system job/zfs-pool-setup"
    } : {
    status      = "DISABLED - Set zfs_pool_enabled = true to automate ZFS pool creation"
    pool_name   = null
    mount_point = null
    disks       = []
    topology    = null
    verify      = null
  }
}

output "argocd_guestbook_status" {
  description = "Status of the ArgoCD guestbook example application"
  value = var.argocd_enabled && var.argocd_deploy_guestbook ? {
    deployed     = true
    note         = null
    app_name     = "guestbook"
    namespace    = "default"
    sync_policy  = "Automated (prune + self-heal)"
    source_repo  = "https://github.com/argoproj/argocd-example-apps.git"
    source_path  = "guestbook"
    view_command = "argocd app get guestbook"
    sync_command = "argocd app sync guestbook"
    } : {
    deployed     = false
    note         = var.argocd_enabled ? "Set argocd_deploy_guestbook = true to deploy the example app" : "ArgoCD not enabled"
    app_name     = null
    namespace    = null
    sync_policy  = null
    source_repo  = null
    source_path  = null
    view_command = null
    sync_command = null
  }
}
