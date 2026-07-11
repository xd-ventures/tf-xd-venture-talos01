# SPDX-License-Identifier: Apache-2.0
# Copyright Maciej Sawicki

# Consumer outputs: re-export the module's outputs (so `tofu output X`
# keeps working from this root, incl. cluster-checks) plus the
# consumer-owned outputs (ArgoCD, Shodan, backup secret command).

output "cluster_health_status" {
  description = "Re-exported from module.talos (cluster_health_status)."
  value       = module.talos.cluster_health_status
}

output "server_id" {
  description = "Re-exported from module.talos (server_id)."
  value       = module.talos.server_id
}

output "server_name" {
  description = "Re-exported from module.talos (server_name)."
  value       = module.talos.server_name
}

output "server_state_actual" {
  description = "Re-exported from module.talos (server_state_actual)."
  value       = module.talos.server_state_actual
}

output "server_ip" {
  description = "Re-exported from module.talos (server_ip)."
  value       = module.talos.server_ip
}

output "talos_schematic_id" {
  description = "Re-exported from module.talos (talos_schematic_id)."
  value       = module.talos.talos_schematic_id
}

output "talos_image_url" {
  description = "Re-exported from module.talos (talos_image_url)."
  value       = module.talos.talos_image_url
}

output "talos_installer_image" {
  description = "Re-exported from module.talos (talos_installer_image)."
  value       = module.talos.talos_installer_image
}

output "installation_image_url" {
  description = "Re-exported from module.talos (installation_image_url)."
  value       = module.talos.installation_image_url
}

output "installation_image_type" {
  description = "Re-exported from module.talos (installation_image_type)."
  value       = module.talos.installation_image_type
}

output "efi_bootloader_path" {
  description = "Re-exported from module.talos (efi_bootloader_path)."
  value       = module.talos.efi_bootloader_path
}

output "cluster_endpoint_actual" {
  description = "Re-exported from module.talos (cluster_endpoint_actual)."
  value       = module.talos.cluster_endpoint_actual
}

output "cluster_endpoint_public" {
  description = "Re-exported from module.talos (cluster_endpoint_public)."
  value       = module.talos.cluster_endpoint_public
}

output "talos_machine_config" {
  description = "Re-exported from module.talos (talos_machine_config)."
  value       = module.talos.talos_machine_config
  sensitive   = true
}

output "talosconfig" {
  description = "Re-exported from module.talos (talosconfig)."
  value       = module.talos.talosconfig
  sensitive   = true
}

output "talosconfig_save_command" {
  description = "Re-exported from module.talos (talosconfig_save_command)."
  value       = module.talos.talosconfig_save_command
}

output "bootstrap_completed" {
  description = "Re-exported from module.talos (bootstrap_completed)."
  value       = module.talos.bootstrap_completed
}

output "kubeconfig" {
  description = "Re-exported from module.talos (kubeconfig)."
  value       = module.talos.kubeconfig
  sensitive   = true
}

output "kubeconfig_save_command" {
  description = "Re-exported from module.talos (kubeconfig_save_command)."
  value       = module.talos.kubeconfig_save_command
}

output "kubeconfig_public_ip" {
  description = "Re-exported from module.talos (kubeconfig_public_ip)."
  value       = module.talos.kubeconfig_public_ip
  sensitive   = true
}

output "tailscale_enabled" {
  description = "Re-exported from module.talos (tailscale_enabled)."
  value       = module.talos.tailscale_enabled
}

output "tailscale_fqdn" {
  description = "Re-exported from module.talos (tailscale_fqdn)."
  value       = module.talos.tailscale_fqdn
}

output "tailscale_device_id" {
  description = "Re-exported from module.talos (tailscale_device_id)."
  value       = module.talos.tailscale_device_id
}

output "tailscale_device_ip" {
  description = "Re-exported from module.talos (tailscale_device_ip)."
  value       = module.talos.tailscale_device_ip
}

output "tailscale_access_info" {
  description = "Re-exported from module.talos (tailscale_access_info)."
  value       = module.talos.tailscale_access_info
}

output "firewall_warning" {
  description = "Re-exported from module.talos (firewall_warning)."
  value       = module.talos.firewall_warning
}

output "firewall_enabled" {
  description = "Re-exported from module.talos (firewall_enabled)."
  value       = module.talos.firewall_enabled
}

output "firewall_status" {
  description = "Re-exported from module.talos (firewall_status)."
  value       = module.talos.firewall_status
}

output "firewall_verification_commands" {
  description = "Re-exported from module.talos (firewall_verification_commands)."
  value       = module.talos.firewall_verification_commands
}

output "zfs_pool_info" {
  description = "Re-exported from module.talos (zfs_pool_info)."
  value       = module.talos.zfs_pool_info
}

output "talos_backup_info" {
  description = "Re-exported from module.talos (talos_backup_info)."
  value       = module.talos.talos_backup_info
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
    monitored_ip = "${module.talos.server_ip}/32"
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

output "talos_backup_secret_command" {
  description = "One-time command creating the in-cluster Secret for the backup CronJobs. Export TALOS_BACKUP_AGE_SECRET_KEY from the password manager first (ADR-0018 decision 4 custody); the age key placeholder expands in YOUR shell, never in state."
  sensitive   = true
  value = var.talos_backup_enabled ? join(" ", [
    "kubectl -n talos-backup create secret generic talos-backup-s3",
    "--from-literal=AWS_ACCESS_KEY_ID=${ovh_cloud_project_user_s3_credential.talos_backup[0].access_key_id}",
    "--from-literal=AWS_SECRET_ACCESS_KEY=${ovh_cloud_project_user_s3_credential.talos_backup[0].secret_access_key}",
    "--from-literal=AGE_SECRET_KEY=\"$TALOS_BACKUP_AGE_SECRET_KEY\"",
  ]) : null
}
