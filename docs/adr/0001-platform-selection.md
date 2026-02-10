# ADR-0001: Platform Selection for OVH BYOI

## Status
Accepted

## Date
2026-02-08

## Context
OVH dedicated servers use Bring Your Own Image (BYOI) for custom OS deployment. The BYOI system creates a config drive that Talos must read to obtain its machine configuration. We need to determine which Talos platform to use for proper config drive detection.

### Challenge
- OVH BYOI creates a config drive with volume label `config-2`
- The config is placed at `openstack/latest/user_data`
- This is OpenStack metadata format, not cloud-init/nocloud format
- Talos platform detection must match the config drive format

### Considered Options

#### Option 1: `platform=metal`
- Generic bare metal platform
- No automatic config drive detection
- Requires manual config or SMBIOS injection
- **Rejected**: OVH provides config drive, we should use it

#### Option 2: `platform=nocloud`
- Expects cloud-init format: `cidata` or `CIDATA` volume label
- Config at `user-data` in root or `nocloud/` subdirectory
- **Rejected**: OVH uses OpenStack format, not nocloud

#### Option 3: `platform=openstack`
- Expects OpenStack format: `config-2` volume label
- Config at `openstack/latest/user_data`
- Matches OVH BYOI behavior exactly
- **Selected**

## Decision
Use `platform=openstack` for OVH BYOI deployments.

### Implementation
```hcl
# In talos_image_factory_schematic
extraKernelArgs = ["talos.platform=openstack"]

# In talos_image_factory_urls
platform = "openstack"
```

## Consequences

### Positive
- Config drive detected automatically at boot
- Machine configuration loaded from correct path
- No manual SMBIOS injection needed

### Negative
- None identified

### Risks
- OVH may change BYOI format in future (low probability)

## References
- [Talos Platform Detection](https://www.talos.dev/v1.11/reference/platforms/)
- [OpenStack Config Drive](https://docs.openstack.org/nova/latest/user/config-drive.html)
- [ADR-0011: OVH Config Drive Format](0011-ovh-config-drive-format.md)
- [inspect-config-drive.sh](../../scripts/inspect-config-drive.sh) — rescue mode diagnostic tool
