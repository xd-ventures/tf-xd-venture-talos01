# ADR-0011: OVH Config Drive Format

## Status
Accepted

## Date
2026-02-10

## Context
OVH dedicated servers use Bring Your Own Image (BYOI) which creates an OpenStack-format config drive alongside the installed OS. Talos Linux reads its machine configuration from config drives at boot, but different Talos platforms expect different config drive formats.

### The Mismatch
- **OVH BYOI creates**: OpenStack format — volume label `config-2`, config at `openstack/latest/user_data`
- **Talos nocloud expects**: cloud-init format — volume label `cidata` or `CIDATA`, config at `user-data` in root

This mismatch meant that Talos with `platform=nocloud` could not detect the OVH config drive. Investigation was needed to identify the correct approach.

### Investigation Methodology
A rescue mode inspection was performed using [inspect-config-drive.sh](../../scripts/inspect-config-drive.sh) to determine the exact config drive format OVH creates. The script enumerates block devices, volume labels, and file structures.

### Considered Options

#### Option 1: SMBIOS Serial Number Method (HTTP server)
- Encode a nocloud network URL in the SMBIOS serial number
- Talos fetches config from an HTTP server at boot
- **Rejected**: Adds unnecessary infrastructure (HTTP server) when OVH already provides a config drive with the correct content

#### Option 2: Embed Config in Image
- Use Talos imager to bake machine config directly into the OS image
- **Rejected**: Inflexible — requires rebuilding the image for any config change

#### Option 3: Manual Application
- Boot into maintenance mode and apply config via `talosctl apply-config`
- **Rejected**: Defeats the purpose of automated provisioning

#### Option 4: `platform=openstack`
- Talos natively supports OpenStack config drives (`config-2` label, `openstack/latest/user_data` path)
- Matches OVH BYOI format exactly
- **Selected**

## Decision
Use `platform=openstack` in the Talos image factory configuration. This tells Talos to look for an OpenStack-format config drive, which matches the format OVH BYOI creates. See [ADR-0001](0001-platform-selection.md) for implementation details.

## Consequences

### Positive
- Config drive detected automatically at boot — no manual steps
- No external infrastructure required (no HTTP server, no image rebuilds)
- Uses OVH's native config drive as-is, zero workarounds

### Negative
- None identified

### Risks
- OVH may change BYOI config drive format in the future (low probability)

## Appendix: Rescue Mode Evidence

The following evidence was captured via rescue mode SSH using `inspect-config-drive.sh`.

### Block Device Layout (blkid)
```
/dev/nvme0n1p5: LABEL="config-2" TYPE="iso9660"
```

### Config Drive File Structure
```
/mnt/config/
└── openstack/
    └── latest/
        ├── user_data        # Talos machine config (raw YAML, 11017 bytes)
        ├── meta_data.json
        ├── network_data.json
        └── vendor_data.json
```

### Key Findings
- Volume label is `config-2` (OpenStack), not `cidata` (cloud-init)
- User data is raw YAML, not base64 encoded
- Content is the correct Talos machine configuration
- File path follows OpenStack metadata convention (`openstack/latest/`)

## References
- [Talos Platform Detection](https://www.talos.dev/v1.11/reference/platforms/)
- [OpenStack Config Drive](https://docs.openstack.org/nova/latest/user/config-drive.html)
- [ADR-0001: Platform Selection](0001-platform-selection.md)
