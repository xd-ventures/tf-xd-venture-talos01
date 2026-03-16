# SPDX-License-Identifier: Apache-2.0
# Copyright Maciej Sawicki

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
#    - Scopes: auth_keys + devices:read + devices:core (recommended)
#      devices:core enables automated stale device cleanup on reinstall (see #156)
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
# We use recreate_if_invalid="never" to suppress expiry-driven recreation.
# On reinstall, replace_triggered_by forces a fresh key directly on this resource.
#
# IMPORTANT: Do NOT use ignore_changes=all here — it blocks replace_triggered_by from
# generating a fresh key on reinstall. The previous proxy pattern (terraform_data.tailscale_key_stable)
# was removed because it silently re-read the same consumed key. See issue #129.
# Clean up stale Tailscale devices before reinstall.
# On reinstall, Tailscale registers a new device. If the old entry still exists,
# Tailscale appends a "-1" suffix (e.g., "my-hostname" → "my-hostname-1"),
# which breaks data.tailscale_device hostname lookup — it finds the STALE device
# with the wrong IP instead of the new one.
#
# This resource runs scripts/tailscale-device-cleanup.py to delete any existing
# devices matching the hostname (exact or suffixed) before the reinstall creates
# a new one. Requires 'devices:core' OAuth scope for DELETE.
resource "terraform_data" "tailscale_device_cleanup" {
  count = local.tailscale_enabled ? 1 : 0

  triggers_replace = [
    terraform_data.reinstall_trigger.id,
  ]

  provisioner "local-exec" {
    command = "python3 ${path.module}/scripts/tailscale-device-cleanup.py"
    environment = {
      TS_CLEANUP_HOSTNAME = var.tailscale_hostname
    }
  }
}

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
    # On reinstall, generate a fresh key. Between reinstalls, the key sits consumed/expired
    # in state — that's fine, it was used once on boot and is now irrelevant.
    replace_triggered_by = [
      terraform_data.reinstall_trigger,
    ]
  }
}

# Tailscale device data source for dynamic IP lookup
# See ADR-0009 for design rationale
#
# This data source waits for the Tailscale device to appear after reinstall.
# The Tailscale extension starts on boot (BEFORE bootstrap), so the device
# appears in the tailnet within seconds of boot. This allows bootstrap to
# use the Tailscale IP when the firewall is enabled.
#
# Requirements:
# - OAuth client needs 'devices:read' scope (included in the recommended setup)
# - Device must already exist in the tailnet
# - tailscale_device_lookup=true by default (set false only for restricted environments)
data "tailscale_device" "talos_node" {
  count = local.tailscale_enabled && var.tailscale_device_lookup ? 1 : 0

  hostname = var.tailscale_hostname
  wait_for = "600s" # Wait up to 10 min for device to appear after reinstall + reboot

  depends_on = [ovh_dedicated_server_reinstall_task.talos]
}

output "tailscale_device_id" {
  description = "Tailscale device ID (from data source lookup)"
  value       = length(data.tailscale_device.talos_node) > 0 ? data.tailscale_device.talos_node[0].id : null
}

output "tailscale_device_ip" {
  description = "Tailscale device IP (from data source lookup, always current)"
  value       = length(data.tailscale_device.talos_node) > 0 ? data.tailscale_device.talos_node[0].addresses[0] : null
}
