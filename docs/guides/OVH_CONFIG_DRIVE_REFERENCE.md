# OVH bare metal config drive: the complete BYO guide

> **Disclaimer**: This reference was compiled from OVH documentation, OpenStack
> specifications, and empirical testing on OVH dedicated servers. OVH may change
> their implementation without notice. Always verify behavior against your actual
> server environment.

**OVH writes a small (~1 MB) read-only partition labeled `config-2` to the last position on your server's primary disk during every provisioning event.** This partition uses the OpenStack config drive v2 format — an ISO 9660 filesystem (for BYOI deployments) or VFAT (for BYOLinux) — containing JSON metadata files your custom OS can mount and parse without cloud-init or any network-based metadata service. OVH bare metal has **no HTTP metadata endpoint** at `169.254.169.254`; the config drive is the sole source of instance metadata. Understanding this mechanism is essential for anyone deploying a non-standard OS, because you must implement your own config drive consumer to retrieve network configuration, SSH keys, hostname, and any custom data you injected via the API.

## Filesystem format and internal directory structure

The config drive follows the **OpenStack metadata format version 2**, with the volume label **`config-2`** (case-insensitive). There is a critical distinction between OVH's two BYO deployment methods:

- **BYOI (`byoi_64`)**: ISO 9660 filesystem, inherently read-only, ~1 MB partition
- **BYOLinux (`byolinux_64`)**: VFAT filesystem, technically writable, placed at the end of the disk

Both use the same `config-2` label and identical internal directory layout. Standard OVH template installs also use ISO 9660. The directory tree follows the OpenStack convention with versioned date directories plus a `latest/` symlink:

```
/
├── openstack/
│   ├── 2012-08-10/
│   ├── 2013-04-04/
│   ├── 2015-10-15/
│   ├── 2017-02-22/
│   └── latest/
│       ├── meta_data.json
│       ├── network_data.json
│       ├── user_data          (only if configDriveUserData was provided)
│       ├── vendor_data.json
│       └── vendor_data2.json
└── ec2/                       (deprecated EC2-compat format; ignore)
    └── latest/
        ├── meta-data.json
        └── user-data
```

**Always read from `openstack/latest/`** — this mirrors the highest available version. The `ec2/` tree is a legacy artifact that may be removed in future OpenStack versions; do not depend on it.

**`meta_data.json`** contains the core instance identity. OVH populates these fields:

```json
{
  "uuid": "12345678-1234-1234-1234-abcdefghijkl",
  "hostname": "myhostname",
  "name": "myhostname",
  "availability_zone": "nova",
  "project_id": "abcdefgh-4321-4321-1234-lkjihgfedcba",
  "launch_index": 0,
  "devices": [],
  "keys": [{"data": "ssh-rsa AAAA...", "type": "ssh", "name": "key1"}],
  "public_keys": {"key1": "ssh-rsa AAAA..."},
  "meta": {}
}
```

The `uuid` field doubles as the **instance ID** that cloud-init uses to detect whether a "new" provisioning has occurred. The `meta` object holds any custom key-value pairs injected via the `configDriveMetadata` API field (exposed in Terraform as `config_drive_metadata`). SSH public keys specified at install time appear in both `keys` and `public_keys`.

**`network_data.json`** provides the complete network topology using the OpenStack format with three top-level arrays: `links`, `networks`, and `services`. For bare metal, links describe physical NICs (type `phy`) by MAC address and MTU, potentially bonds (type `bond` with `bond_mode`, `bond_links`, `bond_xmit_hash_policy`) and VLANs. The `networks` array contains static IPv4/IPv6 assignments with `ip_address`, `netmask`, `gateway`, and `routes`. The `services` array lists DNS servers. This is the **critical file for any custom OS** — without parsing it correctly, your server has no network connectivity.

**`user_data`** contains the raw blob you passed via `configDriveUserData` in the API. It is stored as-is (base64-decoded by OVH before writing). For cloud-init consumers this would be `#cloud-config` YAML or a shell script, but for a custom OS it can be any binary or text payload you choose.

## Where to find it on disk and how to mount it

The config drive is written as the **last partition on the server's primary (first) disk**. Real-world observations confirm this consistently across hardware types. On an NVMe server deploying via BYOI, a Talos Linux user found it at `/dev/nvme0n1p7` — the seventh and final partition. On a SATA server with a standard Proxmox install, it appeared at `/dev/sda5` as the last partition after EFI, ZFS, and swap partitions.

**In multi-disk configurations, the config drive exists only on the first disk.** It is not replicated to RAID mirrors or secondary drives. If your OS assembles a software RAID array from multiple disks, you must explicitly scan the raw member devices (not the RAID array device) to locate the `config-2` partition.

For a custom OS without udev or `/dev/disk/by-label/`, discovery requires scanning partition tables directly. The reliable approach:

```bash
# Method 1: blkid scan (works if blkid is available)
CONFIG_DEV=$(blkid -t LABEL="config-2" -o device | head -1)

# Method 2: Direct device path (NVMe example)
# Enumerate partitions on the first disk, check each for the label
for part in /dev/nvme0n1p*; do
  if blkid "$part" | grep -q 'LABEL="config-2"'; then
    CONFIG_DEV="$part"; break
  fi
done

# Mount (read-only for ISO 9660; optional ro flag for VFAT)
mkdir -p /mnt/configdrive
mount -o ro "$CONFIG_DEV" /mnt/configdrive

# Read the metadata
cat /mnt/configdrive/openstack/latest/meta_data.json
cat /mnt/configdrive/openstack/latest/network_data.json
cat /mnt/configdrive/openstack/latest/user_data 2>/dev/null
```

If your custom OS cannot mount ISO 9660 (e.g., a minimal kernel without the isofs module), you would need to either compile ISO 9660 support into the kernel, use a userspace ISO reader, or switch to BYOLinux deployment which uses VFAT — a simpler filesystem to support. For truly custom/non-Linux systems, consider implementing a raw ISO 9660 parser or reading the partition at the block level.

## Data lifecycle: written once, never updated

The config drive is created **exactly once per provisioning event** — during the OS install or reinstall process. OVH's provisioning system boots the server into a rescue image, wipes disks, creates partitions (including the config drive), deploys your image, and reboots. The config drive **persists across all subsequent reboots** as an ordinary disk partition. OVH never modifies it after the initial write.

**There is no API endpoint to update config drive content post-provisioning.** The only way to change it is to reinstall the server, which destroys all data on disk. This is by design — the ISO 9660 filesystem is physically read-only, and even the VFAT variant (BYOLinux) is not designed to be modified in-place by OVH's infrastructure.

When you reinstall the server, the old config drive partition is destroyed along with all other partitions during the disk-wipe step, and a fresh config drive is created with the new metadata. If you reinstall without specifying `configDriveUserData`, the `user_data` file simply won't exist in the new config drive — but OVH still creates the config drive with `meta_data.json` and `network_data.json` populated from the server's current configuration.

Cloud-init uses the `uuid` field as an instance ID to detect first boot vs. subsequent boots. For a custom OS, you should implement similar logic: read the UUID on first boot, cache it somewhere persistent, and skip re-initialization on subsequent boots when the UUID matches.

## API mechanics for injecting custom metadata in BYO

OVH provides two API paths for BYO deployments. The **current recommended endpoint** is the unified reinstall route:

```
POST /dedicated/server/{serviceName}/reinstall
```

For a BYOI deployment, the request body uses the `customizations` object:

```json
{
  "templateName": "byoi_64",
  "details": {"customHostname": "my-server"},
  "userMetadata": [
    {"key": "imageURL", "value": "https://example.com/my-image.raw"},
    {"key": "imageType", "value": "raw"},
    {"key": "efiBootloaderPath", "value": "\\efi\\boot\\bootx64.efi"},
    {"key": "imageCheckSum", "value": "sha512_hash_here"},
    {"key": "imageCheckSumType", "value": "sha512"},
    {"key": "configDriveUserData", "value": "base64_encoded_content_here"}
  ]
}
```

The **`configDriveUserData`** field accepts a base64-encoded blob (recommended) or cleartext with escaped special characters. This content is written verbatim to `openstack/latest/user_data` inside the config drive. Encode with `base64 -w0` to avoid line breaks.

The Terraform provider additionally exposes **`configDriveMetadata`** — a map of key-value pairs that get injected into the `meta` object inside `meta_data.json`. This is useful for passing structured configuration to a custom OS without relying on the freeform `user_data` blob:

```hcl
customizations {
  config_drive_metadata = {
    role        = "database"
    cluster_id  = "prod-east-1"
    auth_token  = "secret123"
  }
  config_drive_user_data = base64encode(file("my-init-script.sh"))
}
```

**Size constraints**: The config drive partition is approximately **1 MB** on OVH bare metal (per OVH engineering blog). The OpenStack Ironic spec allows up to **64 MB**, but OVH's implementation is smaller. The practical limit for `configDriveUserData` is constrained by this partition size — keep your user data under ~900 KB to be safe. The `user_data` field in OpenStack Nova has a formal limit of **65,535 bytes** before base64 encoding.

The legacy BYOI-specific endpoint (`POST /dedicated/server/{serviceName}/bringYourOwnImage`) uses a slightly different payload structure with a `customizations` object instead of `userMetadata` array, but the config drive output is identical.

## Technical implementation: what OVH runs under the hood

OVH does **not** use OpenStack Ironic directly for their dedicated server product. Their engineering blog describes the system as **"heavily inspired from Ironic, the OpenStack Baremetal module"** — it's a proprietary provisioning stack that follows Ironic's patterns. The deployment sequence, as documented by OVH bare metal system engineer Jérémy Collin, is:

1. Reboot server into PXE rescue image (IPMI used only for power control)
2. Wipe all disks
3. Create partition layout and RAID (if applicable)
4. **Create the config-2 partition** (ISO 9660 or VFAT, ~1 MB, last partition)
5. Mount all partitions to a temp directory
6. Deploy the customer image (rsync for templates, block copy for BYOI)
7. Make bootable (fstab, GRUB, initramfs adjustments)
8. Reboot into the installed OS
9. cloud-init reads config drive, applies configuration, and calls phone-home

**IPMI/BMC is not involved in config drive creation** — it's purely disk-based. IPMI handles power management (PXE boot into rescue, reboot after install) and can be used to monitor deployment via KVM, but the config drive is written entirely from within the rescue image operating environment.

**No meaningful differences exist between OVH product lines** (Eco/Kimsufi, Advance, Scale, High Grade) regarding config drive behavior. All lines use the same provisioning infrastructure and the same config drive format. The only hardware-dependent variation is the device path (`/dev/nvmeXnYpZ` vs. `/dev/sdXN`) and whether hardware RAID is available (which affects where the config drive partition lands — on the RAID logical device for hardware RAID servers, on the raw first disk otherwise).

For BYOI specifically: the server supports **any OS** (not just Linux), accepts `raw` or `qcow2` image formats, requires you to specify `efiBootloaderPath`, and does **not** support software RAID at install time. The image is block-copied directly to disk, and the config drive partition is appended after the image's partition table. This means your image should not consume the entire disk — OVH needs space for the config drive partition at the end.

## Practical checklist for a custom OS config drive consumer

Building a non-Linux or non-standard OS that needs to consume the OVH config drive requires implementing these steps in your init system:

1. **Detect the config drive partition** by scanning for filesystem label `config-2` (ISO 9660 or VFAT)
2. **Mount it read-only** — ISO 9660 enforces this; VFAT should be mounted read-only as a best practice
3. **Parse `openstack/latest/network_data.json`** to configure network interfaces, matching physical NICs by MAC address from the `links` array, applying IP addresses and routes from the `networks` array, and setting DNS from `services`
4. **Parse `openstack/latest/meta_data.json`** for hostname, SSH keys, UUID (instance ID), and any custom metadata in `meta`
5. **Read `openstack/latest/user_data`** if present — treat it as an opaque blob whose format you define via `configDriveUserData` at provisioning time
6. **Cache the UUID** to distinguish first boot from subsequent reboots
7. **Unmount the config drive** — it remains on disk but doesn't need to stay mounted

The config drive is your **only metadata source** on OVH bare metal. There is no fallback HTTP metadata service, no DHCP-based metadata injection, and no out-of-band mechanism. If your OS cannot read the config drive, it boots without network configuration, hostname, or SSH keys. Plan your kernel and userspace accordingly — at minimum, you need ISO 9660 filesystem support (or VFAT if using BYOLinux) and a JSON parser.

## Sources

- [OVH BYOI Documentation](https://help.ovhcloud.com/csm/en-dedicated-servers-bringyourownimage) — official OVH Bring Your Own Image guide
- [OpenStack Config Drive Specification](https://docs.openstack.org/nova/latest/user/metadata.html#config-drives) — upstream config drive format
- [OVH API Reference](https://api.ovh.com/console/#/dedicated/server) — dedicated server API endpoints
- Empirical testing on OVH bare metal servers as part of the [tf-xd-venture-talos01](https://github.com/xd-ventures/tf-xd-venture-talos01) project
