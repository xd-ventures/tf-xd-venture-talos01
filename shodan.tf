# SPDX-License-Identifier: Apache-2.0
# Copyright Maciej Sawicki

# Shodan Network Monitoring
#
# Registers the server's public IP with Shodan Monitor to get alerts
# when services are accidentally exposed to the internet.
# Disabled by default — set shodan_enabled = true and provide API key.
#
# IPv4-only by design (#252): the routed IPv6 block is not monitored —
# Shodan free-tier IP limits make /64 monitoring impractical. IPv6
# exposure protection relies on the Talos firewall rules (see SECURITY.md).

resource "shodan_alert" "server" {
  count = var.shodan_enabled ? 1 : 0

  name        = "${var.cluster_name}-server"
  description = "Monitor ${var.cluster_name} server (${ovh_dedicated_server.talos01.ip}) for accidental exposure"
  network     = ["${ovh_dedicated_server.talos01.ip}/32"]
  enabled     = true

  triggers  = var.shodan_triggers
  notifiers = var.shodan_notifiers
}
