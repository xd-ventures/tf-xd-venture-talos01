# SPDX-License-Identifier: Apache-2.0
# Copyright Maciej Sawicki

# Shodan Network Monitoring
#
# Registers the server's public IP with Shodan Monitor to get alerts
# when services are accidentally exposed to the internet.
# Disabled by default — set shodan_enabled = true and provide API key.

resource "shodan_alert" "server" {
  count = var.shodan_enabled ? 1 : 0

  name        = "${var.cluster_name}-server"
  description = "Monitor ${var.cluster_name} server (${ovh_dedicated_server.talos01.ip}) for accidental exposure"
  network     = ["${ovh_dedicated_server.talos01.ip}/32"]
  enabled     = true

  triggers  = var.shodan_triggers
  notifiers = var.shodan_notifiers
}
