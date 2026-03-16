#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
# Copyright xd-ventures contributors

# Script to inspect OVH config drive format on rescue mode
# Run this after SSHing into rescue mode

set -euo pipefail

echo "=== Inspecting OVH Config Drive Format ==="
echo ""

# 1. List all block devices
echo "1. Listing all block devices:"
lsblk -f
echo ""

# 2. Look for config drive (usually on a separate partition or disk)
echo "2. Looking for config drive partitions:"
for dev in /dev/sd* /dev/nvme*; do
    if [ -b "$dev" ]; then
        echo "Checking $dev:"
        blkid "$dev" 2>/dev/null || echo "  No filesystem found"
    fi
done
echo ""

# 3. Check for cidata/CIDATA volume label
echo "3. Searching for cidata/CIDATA volume labels:"
blkid | grep -i "cidata" || echo "  No cidata volume found"
echo ""

# 4. Mount all partitions and check for user-data
echo "4. Checking mounted filesystems for user-data:"
mkdir -p /tmp/inspect
for dev in /dev/sd*[0-9] /dev/nvme*p*; do
    if [ -b "$dev" ]; then
        label=$(blkid -s LABEL -o value "$dev" 2>/dev/null || echo "")
        if [ -n "$label" ]; then
            echo "  Found partition $dev with label: $label"
            mountpoint="/tmp/inspect/$(basename "$dev")"
            mkdir -p "$mountpoint"
            if mount -r "$dev" "$mountpoint" 2>/dev/null; then
                echo "    Mounted at $mountpoint"
                if [ -f "$mountpoint/user-data" ]; then
                    echo "    ✓ Found user-data file"
                    echo "    Size: $(stat -c%s "$mountpoint/user-data") bytes"
                    echo "    First 100 chars: $(head -c 100 "$mountpoint/user-data")"
                fi
                if [ -f "$mountpoint/meta-data" ]; then
                    echo "    ✓ Found meta-data file"
                    cat "$mountpoint/meta-data"
                fi
                if [ -f "$mountpoint/network-config" ]; then
                    echo "    ✓ Found network-config file"
                fi
                umount "$mountpoint" 2>/dev/null || true
            fi
        fi
    fi
done
echo ""

# 5. Check for OVH-specific config drive locations
echo "5. Checking common OVH config drive locations:"
for path in /mnt/config /media/config /config-drive /var/lib/cloud /mnt; do
    if [ -d "$path" ]; then
        echo "  Checking $path:"
        find "$path" -name "user-data" -o -name "meta-data" 2>/dev/null | head -5
    fi
done
echo ""

# 6. Check if config drive is in a specific partition
echo "6. Detailed partition information:"
fdisk -l 2>/dev/null | grep -A 5 "Disk /dev" | head -30
echo ""

echo "=== Inspection Complete ==="
echo "Look for:"
echo "  - Volume labels containing 'cidata' or 'CIDATA'"
echo "  - Partitions with user-data and meta-data files"
echo "  - The format of user-data (raw YAML vs base64 encoded)"
