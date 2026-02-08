# ADR-0005: Remote Access Strategy

## Status
Accepted

## Date
2026-02-08

## Context
We need secure remote access to the Talos cluster for administration. The cluster should not expose APIs on the public internet.

### Challenge
- Talos API (port 50000) and Kubernetes API (port 6443) must be accessible
- Public IP exposure creates attack surface
- Need secure access for both admin and application users
- Public workloads need separate ingress path

### Considered Options

#### Option 1: Public IP with Firewall
- Expose APIs on public IP
- Use Talos firewall to restrict source IPs
- **Rejected**: Still exposes APIs, IP restrictions are fragile

#### Option 2: VPN (WireGuard/OpenVPN)
- Traditional VPN approach
- Requires VPN server infrastructure
- **Rejected**: Additional infrastructure overhead

#### Option 3: Tailscale
- Zero-trust networking
- WireGuard-based, NAT traversal
- Official Talos extension available
- MagicDNS for easy hostname access
- No infrastructure to manage
- **Selected for admin/user access**

#### Option 4: Cloudflare Tunnel
- Outbound-only connections
- No public ports needed
- WAF and DDoS protection
- **Selected for public workloads**

## Decision
Use hybrid approach:
- **Tailscale**: Admin and internal user access (K8s API, Talos API)
- **Cloudflare Tunnel**: Public workload exposure
- **Firewall**: Block all public IP access

### Access Model
```
                    INTERNET
                        |
        +---------------+---------------+
        |                               |
   [Cloudflare]                    [Blocked]
   (Tunnel Only)                   (Firewall)
        |                               |
        v                               v
+----------------------------------------------------------+
|                    Talos Cluster                          |
|  +------------------------+  +------------------------+  |
|  | Tailscale (100.x.x.x)  |  | Public IP (blocked)    |  |
|  | - Admin access         |  | - No API access        |  |
|  | - User access          |  | - Cloudflare tunnel    |  |
|  +------------------------+  +------------------------+  |
+----------------------------------------------------------+
```

### Implementation
```hcl
# Tailscale extension
systemExtensions = {
  officialExtensions = ["siderolabs/tailscale"]
}

# Tailscale config
ExtensionServiceConfig:
  name: tailscale
  environment:
    - TS_AUTHKEY=${tailscale_authkey}
    - TS_AUTH_ONCE=true
    - TS_HOSTNAME=${hostname}
```

### Firewall Rules
```yaml
# Block all ingress by default
NetworkDefaultActionConfig:
  ingress: block

# Allow only from Tailscale subnets
NetworkRuleConfig:
  ingress:
    - subnet: 100.64.0.0/10   # Tailscale IPv4
    - subnet: fd7a:115c:a1e0::/48  # Tailscale IPv6
```

## Consequences

### Positive
- Zero public attack surface
- Zero-trust model
- No VPN infrastructure needed
- Easy team onboarding (Tailscale invites)
- Cloudflare provides WAF/DDoS for public workloads

### Negative
- Dependency on Tailscale service
- Terraform health check can't resolve ts.net hostnames
- Emergency access requires disabling firewall or iKVM

### Health Check Limitation
The Terraform `talos_cluster_health` provider cannot resolve Tailscale MagicDNS hostnames. This is a known limitation documented in ADR-0007.

## References
- [Tailscale Extension](https://github.com/siderolabs/extensions/blob/main/network/tailscale/README.md)
- [Talos Firewall - NetworkRuleConfig](https://www.talos.dev/v1.11/reference/configuration/)
- [Cloudflare Tunnel](https://developers.cloudflare.com/cloudflare-one/connections/connect-networks/)
