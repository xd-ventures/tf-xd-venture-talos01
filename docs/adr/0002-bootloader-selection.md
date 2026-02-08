# ADR-0002: Bootloader Selection

## Status
Accepted

## Date
2026-02-08

## Context
Talos supports multiple bootloaders depending on the boot mode. We need to select the appropriate bootloader for OVH bare metal servers.

### Challenge
- OVH BYOI supports both BIOS and UEFI boot modes
- Talos 1.10+ defaults to UKI (Unified Kernel Image) with systemd-boot for UEFI
- UKI has stricter requirements (SecureBoot compatibility, EFI variable handling)
- OVH has known issues with EFI variable persistence between reinstalls

### Considered Options

#### Option 1: UKI with systemd-boot (UEFI)
- Modern approach, Talos default for UEFI
- Enables SecureBoot capability
- Single binary containing kernel + initramfs + cmdline
- **Rejected**: OVH has EFI variable persistence issues (GitHub #12300), SecureBoot requires additional setup

#### Option 2: GRUB (BIOS/Legacy)
- Traditional bootloader, proven reliability
- Works with BIOS and UEFI fallback modes
- Kernel arguments can be modified without rebuild
- Better compatibility with OVH BYOI
- **Selected**

## Decision
Use GRUB bootloader for OVH BYOI deployments.

### Implementation
```hcl
# In main.tf
efi_bootloader_path = "\\EFI\\BOOT\\BOOTX64.EFI"

# Do NOT specify bootloader in schematic (uses default GRUB)
# Do NOT use: bootloader = "sd-boot"
```

## Consequences

### Positive
- Proven compatibility with OVH BYOI
- No EFI variable issues
- Simpler debugging (GRUB console available)
- Kernel arguments easily modifiable

### Negative
- Cannot use SecureBoot (requires UKI)
- Less "modern" approach

### Future Considerations
- SecureBoot can be revisited once OVH EFI issues are resolved
- UKI migration would require fresh install

## References
- [Talos Bootloader Documentation](https://www.talos.dev/v1.11/talos-guides/install/bare-metal-platforms/bootloader/)
- [OVH BYOI EFI Issue - GitHub #12300](https://github.com/siderolabs/talos/issues/12300)
