# Documentation Index

## Root Documents

| Document | Description |
|----------|-------------|
| [Architecture Overview](ARCHITECTURE.md) | System design, components, security model, and failure modes |
| [Operations Runbook](OPERATIONS_RUNBOOK.md) | Upgrades, failure recovery, ZFS procedures, and operational cadence |
| [Disaster Recovery](DISASTER_RECOVERY.md) | Scenario-based recovery procedures, rescue mode, IPMI access |
| [Secret Rotation](SECRET_ROTATION.md) | Rotation procedures for OVH, Tailscale, Shodan, and backend credentials |
| [Testing Strategy](TESTING_STRATEGY.md) | Cluster check harness, validation phases, debugging, CI coverage |

## Guides

| Document | Description |
|----------|-------------|
| [GitOps Setup](guides/GITOPS_SETUP.md) | dflook plan/apply/drift workflows — secrets, enablement, caveats (ADR-0014) |
| [OVH BYOI Guide](guides/OVH_BYOI_GUIDE.md) | OVH Bring Your Own Image process for Talos deployment |
| [OVH Config Drive Reference](guides/OVH_CONFIG_DRIVE_REFERENCE.md) | In-depth reference on OVH bare metal config drive format and internals |
| [Console Access](guides/CONSOLE_ACCESS.md) | iKVM, IPMI Serial Over LAN, and rescue mode access |

## Incidents

| Document | Description |
|----------|-------------|
| [Config Drive YAML Parse Outage](incidents/2026-02-config-drive-yaml-parse.md) | RCA for 12-day outage caused by OVH cleartext escape processing |

## Architecture Decision Records

See [adr/README.md](adr/README.md) for the full ADR index.
