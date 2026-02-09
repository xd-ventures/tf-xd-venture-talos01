# Config Drive Format Analysis

## Root Cause Identified

**OVH creates OpenStack format config drive:**
- Volume label: `config-2` (OpenStack format)
- File location: `openstack/latest/user_data`
- File content: ✅ Correct (raw YAML, 11017 bytes)
- File format: ✅ Correct (not base64 encoded)

**Talos nocloud expects cloud-init format:**
- Volume label: `cidata` or `CIDATA` (cloud-init format)
- File location: `user-data` (in root directory)
- File content: ✅ Correct
- File format: ✅ Correct

**Result:** Talos nocloud platform does NOT support OpenStack's `config-2` format. It only looks for `cidata`/`CIDATA` volume labels and `user-data` in root.

## Evidence from Rescue Mode Inspection

```bash
# Config drive partition
/dev/nvme0n1p5: LABEL="config-2" TYPE="iso9660"

# File structure
/mnt/config/
└── openstack/
    └── latest/
        ├── user_data      ✅ Correct content (raw YAML)
        ├── meta_data.json
        ├── network_data.json
        └── vendor_data.json
```

## Solutions

### Option 1: SMBIOS Serial Number Method (Recommended)
Use Talos's SMBIOS serial number method to fetch config from HTTP server.

**Requirements:**
- HTTP server accessible from the node
- SMBIOS serial number set to: `ds=nocloud-net;s=http://<server-ip>/configs/;h=<hostname>`
- Config files hosted at: `http://<server-ip>/configs/user-data`

**Pros:**
- Works with OVH BYOI
- No maintenance mode needed
- Fully automated

**Cons:**
- Requires HTTP server setup
- Requires network connectivity before config fetch

### Option 2: Embed Config in Image
Use Talos imager to embed the machine config directly in the image.

**Requirements:**
- Modify image before deployment
- Use Talos imager with `--config` parameter

**Pros:**
- No external dependencies
- Works offline

**Cons:**
- Requires image modification step
- Less flexible (config baked into image)

### Option 3: Accept Manual Application (Not Recommended)
Manually apply config once in maintenance mode.

**Pros:**
- Simple, works immediately

**Cons:**
- Defeats the purpose of automated initialization
- Requires maintenance mode access

## Recommendation

Implement **Option 1: SMBIOS Serial Number Method** with a simple HTTP server to host the config files. This provides full automation while working with OVH's limitations.
