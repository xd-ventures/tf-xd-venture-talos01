# ADR-0008: Tailscale Authentication Strategy for Terraform

## Status

Accepted

## Date

2025-02-08

## Context

We are deploying a Talos Kubernetes cluster on OVH bare metal using OpenTofu/Terraform. The cluster requires Tailscale for secure API access, blocking public IP access and allowing only Tailscale network traffic.

The question is how to authenticate Terraform with Tailscale to manage node registration. There are multiple approaches with different security and operational trade-offs.

### Authentication Options

1. **Direct Auth Key** (`tskey-auth-...`) - User-generated key passed as variable
2. **API Key** (`tskey-api-...`) - Full API access for Terraform provider
3. **OAuth Client** - Scoped API access with specific permissions
4. **OIDC Workload Identity** - Federated identity (GitHub Actions, AWS IAM, etc.)

### Key Challenges Discovered

During implementation, we encountered several issues with the direct auth key approach:

1. **One-time vs Reusable Keys**: One-time keys are most secure but fail on Terraform re-apply. Reusable keys create operational issues.

2. **Duplicate Node Problem**: With reusable keys, cluster redeployment can create duplicate entries in Tailscale (documented in [tailscale#8679](https://github.com/tailscale/tailscale/issues/8679) and [tailscale#10424](https://github.com/tailscale/tailscale/issues/10424)).

3. **Tag Management**: Auth keys cannot create or manage tags - must be done manually.

4. **Key Rotation**: Auth keys expire (max 90 days), requiring manual rotation.

## Considered Options

### Option 1: Direct Auth Key

**Approach**: Generate auth key manually via Tailscale admin console, pass as Terraform variable.

**Pros**:
- True minimum privilege - can only register devices
- Simple mental model
- No provider authentication complexity

**Cons**:
- Lifecycle mismatch with Terraform (one-time fails on re-apply)
- Manual rotation burden (keys expire)
- Duplicate node problem with reusable keys
- No programmatic tag management
- No link between key and resulting device in state

### Option 2: API Key

**Approach**: Use Tailscale API key to authenticate provider, generate auth keys dynamically.

**Pros**:
- Fresh, single-use keys per deployment
- Full lifecycle management
- Tag management capability
- No duplicate nodes (single-use keys)

**Cons**:
- **Overly broad permissions** - full tailnet admin access
- Long-lived credential (doesn't expire unless revoked)
- Large blast radius if compromised
- Tailscale explicitly recommends against this for automation

From [Tailscale documentation](https://tailscale.com/kb/1210/terraform-provider):
> "We recommend that you use an OAuth client because an OAuth client is associated with the tailnet, not an individual user, does not expire, and supports scopes."

### Option 3: OAuth Client with Scoped Permissions (Selected)

**Approach**: Create Tailscale OAuth client with specific scopes, use for Terraform provider authentication.

**Pros**:
- **Scoped permissions** - limit to `auth_keys` scope only
- Non-expiring credential (unlike API keys)
- Tailnet-associated, not tied to individual user
- Fresh keys per deployment (same lifecycle benefits as API key)
- Official Tailscale recommendation for automation

**Cons**:
- Requires ACL policy changes for tag ownership
- Still a long-lived secret (must be stored securely)
- OAuth client must specify allowed tags upfront

### Option 4: OIDC Workload Identity Federation

**Approach**: Use federated identity to obtain short-lived Tailscale tokens.

**Pros**:
- No long-lived secrets
- Audit trail tied to identity provider
- Minimal exposure window

**Cons**:
- Complex setup requiring OIDC trust configuration
- Provider-dependent (CI/CD or cloud provider lock-in)
- Not suitable for local Terraform runs
- Newer feature with less community experience

## Decision

Use **OAuth Client with `auth_keys` scope** for Tailscale authentication in Terraform.

### Blast Radius Comparison

| Credential Type | Compromise Impact |
|-----------------|-------------------|
| Auth Key (one-time) | Register one device only |
| Auth Key (reusable) | Flood tailnet with unauthorized nodes |
| API Key | **Full tailnet admin access** |
| OAuth (`auth_keys`) | Generate auth keys for allowed tags only |

### Required Scopes

| Scope | Purpose | Required |
|-------|---------|----------|
| `auth_keys` | Generate pre-auth keys for device registration | Yes |
| `devices:read` | Auto-discover Tailscale IP (`tailscale_device_lookup=true`) | Optional |
| `devices:core` | Delete/manage devices (for cleanup on destroy) | Optional |

### Implementation

#### 1. ACL Policy Configuration

Add to Tailscale ACL policy:
```json
{
  "tagOwners": {
    "tag:k8s-cluster": ["tag:terraform"],
    "tag:terraform": []
  }
}
```

#### 2. OAuth Client Creation

In Tailscale Admin Console -> Settings -> OAuth clients:
- Scopes: `auth_keys` (minimum) or `auth_keys` + `devices:core`
- Tags: `tag:terraform` (owns `tag:k8s-cluster`)

#### 3. Environment Variables

```bash
# Instead of TAILSCALE_API_KEY, use:
TAILSCALE_OAUTH_CLIENT_ID=...
TAILSCALE_OAUTH_CLIENT_SECRET=...
```

#### 4. Terraform Configuration (No Changes Needed)

The existing provider configuration already supports OAuth:
```hcl
provider "tailscale" {
  # Auth configured via environment variables
}
```

The existing `tailscale_tailnet_key` resource configuration is correct:
```hcl
resource "tailscale_tailnet_key" "talos" {
  reusable      = false  # Single-use key - prevents duplicates
  ephemeral     = false  # Persistent device - survives reboots
  preauthorized = true   # Auto-approve
  expiry        = 3600   # 1 hour - only needs to last through deployment
  tags          = var.tailscale_tags

  recreate_if_invalid = "always"
}
```

## Consequences

### Positive

- Reduced blast radius compared to API keys
- Fully automated deployments without manual key management
- Clean Terraform lifecycle support
- Tag-based access control for generated auth keys
- Aligned with Tailscale's official recommendations

### Negative

- Requires ACL policy configuration for tag ownership
- OAuth client secret is still a long-lived credential
- Device cleanup on destroy requires manual intervention or `devices:core` scope

### Duplicate Node Mitigation

The duplicate node problem (registering same cluster twice) is mitigated by:
1. Using `reusable = false` - each deployment gets unique single-use key
2. Using `TS_AUTH_ONCE=true` in Talos config - key consumed immediately
3. Documenting cleanup step in rebuild runbook

Until Tailscale implements auth key to node ID pre-association, full cluster rebuilds should include manual removal of the old device from the tailnet.

## Credential Rotation

| Credential | Rotation |
|------------|----------|
| OAuth client secret | Quarterly recommended, manual process |
| OAuth access tokens | Automatic (1 hour), provider handles refresh |
| Auth keys (generated) | Per-deployment, 1 hour expiry, consumed immediately |

## References

- [Tailscale OAuth Clients Documentation](https://tailscale.com/kb/1215/oauth-clients)
- [Tailscale Trust Credentials](https://tailscale.com/kb/1623/trust-credentials)
- [Tailscale Terraform Provider](https://tailscale.com/kb/1210/terraform-provider)
- [GitHub: Auth key with pre-associated nodeId](https://github.com/tailscale/tailscale/issues/10424)
- [GitHub: Duplicate node on restart](https://github.com/tailscale/tailscale/issues/8679)
