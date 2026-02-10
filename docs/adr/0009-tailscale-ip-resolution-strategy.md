# ADR-0009: Tailscale IP Address Resolution for Terraform Operations

## Status

Accepted

## Date

2026-02-08

## Context

When deploying Talos clusters with Tailscale for secure access, Terraform needs the Tailscale IP address to:

1. Apply post-bootstrap configurations (firewall rules)
2. Communicate with Talos API when public IP is blocked

### Problem Encountered

During a server reinstall:
1. Old device (`talos-xd-venture`) remained in Tailscale as offline
2. New registration created `talos-xd-venture-1` with a different IP
3. `terraform.tfvars` contained stale IP `100.125.126.73`
4. Firewall apply failed: "dial tcp 100.125.126.73:50000: i/o timeout"

### Root Cause

1. **Hardcoded IPs are static state** - `terraform.tfvars` is not updated on reinstall
2. **Tailscale IPs are dynamic** - Assigned at registration time, not reservable
3. **MagicDNS not available to providers** - Terraform/gRPC uses pure Go resolver
4. **Device lifecycle gap** - New device gets new IP, old tfvars has stale IP

## Considered Options

### Option 1: Manual IP Update in tfvars (Current)

Update `tailscale_ip` in `terraform.tfvars` after each reinstall.

**Pros**: Simple, explicit
**Cons**: Error-prone, requires manual step, breaks automation

### Option 2: Use ts.net Hostname Directly

Use MagicDNS hostname instead of IP.

**Pros**: Hostname is stable across reinstalls
**Cons**: Terraform providers use pure Go resolver which does not support MagicDNS; requires Tailscale on the Terraform runner

### Option 3: tailscale_device Data Source with Wait

Look up device IP dynamically via Tailscale API.

```hcl
data "tailscale_device" "talos_node" {
  hostname = var.tailscale_hostname
  wait_for = "180s"
  depends_on = [talos_machine_bootstrap.this]
}
```

**Pros**: Always gets current IP, fully automated
**Cons**: Adds 0-180s to apply time, requires devices:read scope in OAuth client

### Option 4: Two-Phase Deployment

Phase 1: Bootstrap without firewall
Phase 2: Apply firewall after manual verification

**Pros**: Safe, explicit verification step
**Cons**: Cannot be fully automated, requires human in loop

### Option 5: Bake Firewall into Initial Config

Include firewall rules in initial machine configuration.

**Pros**: No second apply needed, no IP resolution problem
**Cons**: Risk of lockout on first deploy if Tailscale fails

## Decision

**Primary**: Use `tailscale_device` data source with `wait_for` parameter (Option 3)
**Fallback**: Manual IP override via variable (Option 1)
**Safety**: Keep two-phase deployment for initial cluster creation (Option 4)

### Implementation

```hcl
# variables.tf
variable "tailscale_device_lookup" {
  description = "Auto-discover Tailscale IP via API. Set false for fresh deploys."
  type        = bool
  default     = true
}

# tailscale.tf
data "tailscale_device" "talos_node" {
  count    = local.tailscale_enabled && var.tailscale_device_lookup ? 1 : 0
  hostname = var.tailscale_hostname
  wait_for = "180s"
  depends_on = [talos_machine_bootstrap.this]
}

# talos.tf
locals {
  tailscale_endpoint_ip = (
    length(data.tailscale_device.talos_node) > 0
    ? data.tailscale_device.talos_node[0].addresses[0]
    : coalesce(var.tailscale_ip, local.cluster_ip)
  )
}
```

### Workflow

**Automatic Discovery (default, recommended):**

The standard two-phase deployment uses `tailscale_device_lookup=true` (default).
Requires `devices:read` OAuth scope.

```bash
# Phase 1: Bootstrap without firewall (device doesn't exist yet in tailnet)
tofu apply -var="enable_firewall=false"

# Verify Tailscale connectivity
tofu output firewall_verification_commands

# Phase 2: Enable firewall (data source resolves Tailscale IP automatically)
tofu apply -var="enable_firewall=true"
```

**Reinstall:**
```bash
# Delete old device from Tailscale admin (or let it auto-rename)
tofu apply  # Data source waits for new device, gets new IP automatically
```

**Manual IP Management (advanced, not validated by maintainers):**

Setting `tailscale_device_lookup=false` disables automatic IP discovery. You
MUST then provide `tailscale_ip` manually if the firewall is enabled, or
Terraform will attempt to apply firewall rules via the public IP, which will
result in lockout. This path exists for environments where the `devices:read`
OAuth scope cannot be granted. It requires manual IP management on every
reinstall. A `precondition` on the firewall resource will fail the plan if
neither lookup nor manual IP is configured.

```bash
tofu apply -var="tailscale_device_lookup=false" -var="tailscale_ip=100.x.y.z" -var="enable_firewall=true"
```

## Consequences

### Positive

- Eliminates stale IP problem on reinstalls
- Fully automated once device exists
- Variable fallback for edge cases
- Clear workflow for fresh vs reinstall

### Negative

- Up to 180s added to apply time (waiting for device)
- Requires `devices:read` scope in OAuth client
- Fresh deploys still need two-phase approach

### Device Naming Conflict

On reinstall, old offline device blocks hostname. Mitigation options:
1. Manual: Delete old device before reinstall
2. Automated: Use `devices:core` scope to delete stale devices
3. Accept: Use auto-renamed device (`-1` suffix) with explicit rename after

## Future Considerations

- Tailscale may add device ID pre-registration (issue #10424)
- Alternative: Run Terraform from a Tailscale-connected machine with working MagicDNS
- Consider Tailscale ACLs to control which devices can reach cluster APIs

## References

- [Tailscale device data source](https://registry.terraform.io/providers/tailscale/tailscale/latest/docs/data-sources/device)
- [GitHub: Auth key with pre-associated nodeId](https://github.com/tailscale/tailscale/issues/10424)
- ADR-0005: Remote Access Strategy
- ADR-0008: Tailscale Authentication Strategy
