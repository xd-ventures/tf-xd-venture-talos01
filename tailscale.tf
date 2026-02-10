# Tailscale Provider Configuration
#
# Authentication: OAuth Client (RECOMMENDED)
# See ADR-0008 for decision rationale.
#
# Setup:
# 1. Create ACL policy for tag ownership:
#    {"tagOwners": {"tag:k8s-cluster": ["tag:terraform"], "tag:terraform": []}}
#
# 2. Create OAuth client at: Tailscale Admin -> Settings -> OAuth clients
#    - Scopes: auth_keys (minimum), optionally devices:core for cleanup
#    - Tags: tag:terraform
#
# 3. Set environment variables:
#    - TAILSCALE_OAUTH_CLIENT_ID="..."
#    - TAILSCALE_OAUTH_CLIENT_SECRET="..."
#
# Why OAuth over API Key?
# - Scoped permissions (auth_keys only vs full admin)
# - Non-expiring credentials
# - Tailnet-associated, not user-associated
# - Official Tailscale recommendation for automation

provider "tailscale" {
  # Auth configured via environment variables
}

# Generate a pre-authentication key for Talos cluster nodes
# This key is used to automatically register the node with Tailscale
resource "tailscale_tailnet_key" "talos" {
  count = local.tailscale_enabled ? 1 : 0

  reusable      = false                                                # Single-use key (matches TS_AUTH_ONCE=true)
  ephemeral     = false                                                # Persistent device (not removed when offline)
  preauthorized = true                                                 # Auto-approve the device (no manual approval needed)
  expiry        = 3600                                                 # 1 hour expiry (only needs to last through deployment)
  description   = replace(replace(var.cluster_name, "-", ""), "_", "") # Alphanumeric only
  tags          = var.tailscale_tags

  # Recreate key if it becomes invalid (expired, revoked, etc.)
  recreate_if_invalid = "always"
}

# Tailscale device data source for dynamic IP lookup
# See ADR-0009 for design rationale
#
# This data source waits for the Tailscale device to appear after bootstrap
# and returns the current IP address. This avoids stale IPs in terraform.tfvars.
#
# Requirements:
# - OAuth client needs 'devices:read' scope (not included in the default auth_keys-only setup)
# - Device must already exist in the tailnet
# - Set tailscale_device_lookup=true to enable (default: false)
data "tailscale_device" "talos_node" {
  count = local.tailscale_enabled && var.tailscale_device_lookup ? 1 : 0

  hostname = var.tailscale_hostname
  wait_for = "180s" # Wait up to 3 min for device to appear after bootstrap

  depends_on = [talos_machine_bootstrap.this]
}

output "tailscale_device_id" {
  description = "Tailscale device ID (from data source lookup)"
  value       = length(data.tailscale_device.talos_node) > 0 ? data.tailscale_device.talos_node[0].id : null
}

output "tailscale_device_ip" {
  description = "Tailscale device IP (from data source lookup, always current)"
  value       = length(data.tailscale_device.talos_node) > 0 ? data.tailscale_device.talos_node[0].addresses[0] : null
}

output "tailscale_key_id" {
  description = "ID of the generated Tailscale auth key"
  value       = local.tailscale_enabled ? tailscale_tailnet_key.talos[0].id : null
}

output "tailscale_key_expires_at" {
  description = "Expiry time of the generated Tailscale auth key"
  value       = local.tailscale_enabled ? tailscale_tailnet_key.talos[0].expires_at : null
}
