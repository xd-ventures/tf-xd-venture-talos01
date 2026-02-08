# ADR-0007: Health Check Strategy

## Status
Accepted

## Date
2026-02-08

## Context
Terraform's `talos_cluster_health` data source is used to verify cluster health before proceeding with dependent resources. However, there's a known limitation with Tailscale.

### Challenge
The Terraform Talos provider uses its own gRPC DNS resolver, which:
- Does NOT use system DNS settings
- Cannot resolve Tailscale MagicDNS (*.ts.net) hostnames
- Cannot reach Tailscale IPs (100.x.x.x) from outside the Tailscale network

### Root Cause Analysis
1. Terraform provider's gRPC client has internal DNS resolution
2. MagicDNS resolution requires Tailscale daemon running on the machine
3. Even using Tailscale IP directly fails (not routable from outside)
4. Two-phase installation doesn't help (DNS resolver is the issue)

### Considered Options

#### Option 1: Skip Health Check Entirely
- Set `count = 0` when Tailscale enabled
- Rely on bootstrap resource internal readiness
- **Selected** (current implementation)

#### Option 2: Use Public IP for Health Check
- Always health check via public IP
- Apply firewall after health check passes
- **Rejected**: Creates race condition if firewall applied too early

#### Option 3: External Health Check Script
- Use `null_resource` with local-exec
- Run `talosctl health` from operator machine (has Tailscale)
- **Considered for future**: Adds complexity

## Decision
Skip Terraform health check when Tailscale is enabled. Rely on:
1. Bootstrap resource internal readiness wait
2. Manual verification via `talosctl health`

### Implementation
```hcl
data "talos_cluster_health" "this" {
  count = local.tailscale_enabled ? 0 : 1
  # ...
}
```

### Manual Verification
```bash
# After deployment, verify health manually
talosctl --endpoints $(dig +short hostname.ts.net) health

# Or via Tailscale IP
talosctl --endpoints 100.x.x.x health
```

## Consequences

### Positive
- Avoids false failures from DNS resolution issues
- Bootstrap still verifies basic API readiness
- Simple implementation

### Negative
- No automated health verification in Terraform
- Requires manual health check step
- Could proceed with unhealthy cluster

### Mitigation
- Document manual verification in deployment workflow
- Add verification script for automation
- Consider external health check in CI/CD pipeline

### Future Improvements
- Monitor Terraform provider for fixes
- Consider custom health check resource using operator's Tailscale connection

## References
- [talosctl DNS Issues - GitHub #9324](https://github.com/siderolabs/talos/issues/9324)
- [talos_cluster_health Provider Docs](https://registry.terraform.io/providers/siderolabs/talos/latest/docs/data-sources/cluster_health)
