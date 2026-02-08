# Architecture Decision Records

This directory contains Architecture Decision Records (ADRs) documenting key technical decisions made for this project.

## Index

| ADR | Title | Status | Summary |
|-----|-------|--------|---------|
| [0001](0001-platform-selection.md) | Platform Selection | Accepted | Use `openstack` platform for OVH BYOI |
| [0002](0002-bootloader-selection.md) | Bootloader Selection | Accepted | Use GRUB (not UKI) for OVH compatibility |
| [0003](0003-cni-selection.md) | CNI Selection | Accepted | Use Cilium with Hubble and Gateway API |
| [0004](0004-storage-strategy.md) | Storage Strategy | Accepted | ZFS mirror for data, single disk for system |
| [0005](0005-remote-access.md) | Remote Access | Accepted | Tailscale for admin, Cloudflare Tunnel for public |
| [0006](0006-remote-state-backend.md) | Remote State Backend | Accepted | OVH Object Storage (S3-compatible) |
| [0007](0007-health-check-strategy.md) | Health Check Strategy | Accepted | Skip Terraform health check with Tailscale |
| [0008](0008-tailscale-authentication-strategy.md) | Tailscale Authentication | Accepted | OAuth client with `auth_keys` scope |
| [0009](0009-tailscale-ip-resolution-strategy.md) | Tailscale IP Resolution | Accepted | Dynamic lookup via `tailscale_device` data source |
| [0010](0010-terraform-state-migration-to-ovh-object-storage.md) | State Migration to OVH | Proposed | Implementation plan for local-to-remote state migration |

## ADR Format

Each ADR follows this structure:

```markdown
# ADR-NNNN: Title

## Status
[Proposed | Accepted | Deprecated | Superseded]

## Date
YYYY-MM-DD

## Context
What is the issue that we're seeing that is motivating this decision?

## Considered Options
What options did we consider?

## Decision
What is the change that we're proposing and/or doing?

## Consequences
What becomes easier or more difficult to do because of this change?
```

## Creating a New ADR

1. Copy the template from any existing ADR
2. Number it sequentially (0008, 0009, etc.)
3. Update this README index
4. Link related ADRs if applicable
