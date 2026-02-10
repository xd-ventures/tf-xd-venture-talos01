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
#    - Scopes: auth_keys + devices:read (recommended)
#      Add devices:core for automated device cleanup on destroy
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
# This key is consumed once during bootstrap (TS_AUTH_ONCE=true) and has no value after.
# The key expires after 1 hour, but that's fine — it's only needed during initial setup.
#
# DRIFT PREVENTION: The key is a transient credential that expires server-side after 1h.
# Without lifecycle guards, every `tofu plan` after expiry would show a recreate diff.
# We use ignore_changes + recreate_if_invalid="never" to suppress this. On reinstall,
# replace_triggered_by on the terraform_data proxy forces a fresh key.
resource "tailscale_tailnet_key" "talos" {
  count = local.tailscale_enabled ? 1 : 0

  reusable      = false                                                # Single-use key (matches TS_AUTH_ONCE=true)
  ephemeral     = false                                                # Persistent device (not removed when offline)
  preauthorized = true                                                 # Auto-approve the device (no manual approval needed)
  expiry        = 3600                                                 # 1 hour expiry (only needs to last through deployment)
  description   = replace(replace(var.cluster_name, "-", ""), "_", "") # Alphanumeric only
  tags          = var.tailscale_tags

  recreate_if_invalid = "never" # Key is consumed once — don't recreate on expiry

  lifecycle {
    ignore_changes = all # After creation, never diff against Tailscale API state
  }
}

# Stable proxy for the auth key value — decouples downstream resources from the
# tailscale_tailnet_key lifecycle. Without this, key expiry would cascade changes
# through the machine config and firewall resources.
#
# On reinstall, replace_triggered_by forces a new key + new proxy in one operation.
resource "terraform_data" "tailscale_key_stable" {
  count = local.tailscale_enabled ? 1 : 0

  input = tailscale_tailnet_key.talos[0].key

  lifecycle {
    ignore_changes = [input] # Capture once, never re-read from expired key

    replace_triggered_by = [
      terraform_data.reinstall_trigger,
    ]
  }
}

# Tailscale device data source for dynamic IP lookup
# See ADR-0009 for design rationale
#
# This data source waits for the Tailscale device to appear after bootstrap
# and returns the current IP address. This avoids stale IPs in terraform.tfvars.
#
# Requirements:
# - OAuth client needs 'devices:read' scope (included in the recommended setup)
# - Device must already exist in the tailnet
# - tailscale_device_lookup=true by default (set false only for restricted environments)
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

