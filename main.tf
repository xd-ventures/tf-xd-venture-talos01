# Data source to reference the existing OVH Bare Metal Server
# No import is needed for data sources - they query the existing infrastructure
data "ovh_dedicated_server" "talos01" {
  service_name = var.service_name
}

# Resource to manage the existing server's updateable properties
# This resource needs to be imported using:
# tofu import ovh_dedicated_server_update.talos01 <service_name>
resource "ovh_dedicated_server_update" "talos01" {
  service_name = var.service_name
  boot_id      = data.ovh_dedicated_server.talos01.boot_id
  monitoring   = var.monitoring_enabled
  state        = var.server_state
}
