# ADR-0004: Storage Strategy

## Status
Accepted

## Date
2026-02-08

## Context
The target server has 2x 960GB NVMe SSDs. We need a storage strategy that provides:
1. Reliable Talos system storage
2. Data redundancy for application workloads
3. Support for local-path-provisioner

### Challenge
- OVH SSDs have reliability concerns (user experience)
- Single disk for data is unacceptable SPOF
- Need generic configuration that works with different disk setups
- Talos has limitations with software RAID

### Considered Options

#### Option 1: mdadm RAID1 for Boot + Data
- Full disk mirroring at block level
- GRUB can boot from mdraid with metadata 1.0
- **Rejected**:
  - Talos doesn't officially support mdadm
  - UserVolumeConfig can't find /dev/md* devices (GitHub #11098)
  - Talos upgrades may break RAID config
  - Requires manual pre-creation in rescue mode

#### Option 2: LVM Mirroring
- Logical volume management with mirror capability
- LVM binary included in Talos
- **Rejected**:
  - dm-raid kernel module NOT included in Talos
  - LVM mirror requires dm-raid
  - No viable workaround

#### Option 3: Single Disk (No Redundancy)
- Simple, fully supported
- System disk = data disk
- **Rejected**: Unacceptable SPOF for data

#### Option 4: ZFS Mirror for Data
- Official `siderolabs/zfs` extension available
- Native mirroring, RAID-Z support
- Automatic pool import on boot
- Checksumming and self-healing
- System disk on single NVMe (Talos-managed)
- Data on ZFS mirror across remaining space
- **Selected**

## Decision
Use ZFS for data storage with mirroring across both NVMe SSDs.

### Disk Layout
```
NVMe 0 (960GB)              NVMe 1 (960GB)
+------------------+        +------------------+
| Talos System     |        |                  |
| (~20GB)          |        |                  |
| - EFI/BOOT       |        |                  |
| - STATE          |        |                  |
| - META           |        |                  |
+------------------+        |                  |
| EPHEMERAL (/var) |        |                  |
| (100GiB, capped) |        |                  |
+------------------+        |                  |
| ZFS Partition    |        | ZFS Partition    |
| (~840GB)         |<------>| (~940GB)         |
+------------------+        +------------------+
         |                          |
         +------------+-------------+
                      |
              +-------v-------+
              |  ZFS Pool     |
              |  "tank"       |
              |  (mirror)     |
              +---------------+
                      |
              /var/mnt/data
```

EPHEMERAL is capped at 100GiB via Talos `VolumeConfig` (`ephemeral_max_size` variable),
leaving ~840GB free on NVMe 0 for the ZFS partition. Without capping, EPHEMERAL would
consume all remaining space (~890GB), leaving only a ~1.9GB gap for ZFS.
The cap only takes effect on fresh installs (matches the OVH BYOI reinstall flow).

### Implementation
```hcl
# Add ZFS extension to schematic
systemExtensions = {
  officialExtensions = [
    "siderolabs/zfs",
    # ... other extensions
  ]
}

# Machine config for ZFS
machine:
  kernel:
    modules:
      - name: zfs
  install:
    diskSelector:
      match: disk.transport == 'nvme'
```

### ZFS Pool Creation (Post-Install)

ZFS pool creation is automated via a Kubernetes Job (inline manifest applied during bootstrap).
The Job runs as a privileged container and must work within Talos's immutable, shell-less constraints.

#### Talos Host Binary Landscape

Talos has **no shell** (`/bin/sh`, `/bin/bash`) and **no partition tools** (`sfdisk`, `sgdisk`, `fdisk`)
on the host filesystem. Available host binaries:

| Host Path | Contents |
|-----------|----------|
| `/sbin/` | LVM tools, iptables, mkfs.*, cryptsetup, containerd |
| `/usr/local/sbin/` | `zpool`, `zfs`, `zdb`, `zed` (from `siderolabs/zfs` extension) |

The ZFS extension installs userspace tools at `/usr/local/sbin/` via overlayfs.

#### Job Strategy

1. **Container image**: Alpine (not busybox) — `apk add util-linux` provides `sfdisk`
2. **Partitioning**: Runs `sfdisk` directly from the container (privileged mode grants `/dev/` access)
3. **ZFS commands**: Uses `nsenter --mount=/proc/1/ns/mnt -- /usr/local/sbin/zpool` to access host ZFS tools
4. **Block device checks**: Uses `test -b` directly from container (devices visible in privileged mode)

```bash
# Inside the privileged Alpine container:
ZPOOL="nsenter --mount=/proc/1/ns/mnt -- /usr/local/sbin/zpool"

# Partition directly from container (sfdisk from Alpine's util-linux)
echo ", , 6a898cc3-1dd2-11b2-99a6-080020736631" | sfdisk --append /dev/nvme0n1

# Create pool via host zpool binary
$ZPOOL create tank mirror /dev/nvme0n1p3 /dev/nvme1n1p1
```

## Consequences

### Positive
- Data redundancy via ZFS mirror
- Checksumming detects/corrects bit rot
- Snapshots for backup integration (Velero)
- No UserVolumeConfig bugs (ZFS manages devices)
- Generic disk detection via diskSelector

### Negative
- System disk is single point of failure
- ZFS pool creation requires post-install step
- Additional complexity vs single disk

### Trade-off Acknowledgment
- **System disk failure**: Reinstall via Terraform (~15 min)
- **Data disk failure**: ZFS handles transparently (mirror)
- **Both disks fail**: Full restore from backup required

### Future Considerations
- Multi-node deployment would provide additional redundancy
- Velero for backup to S3-compatible storage

## References
- [ZFS Extension - siderolabs/extensions](https://github.com/siderolabs/extensions/blob/main/storage/zfs/README.md)
- [mdadm Issues - GitHub #11098](https://github.com/siderolabs/talos/issues/11098)
- [dm-raid Not Available - GitHub #7483](https://github.com/siderolabs/talos/issues/7483)
