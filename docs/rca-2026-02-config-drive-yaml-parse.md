# RCA: Talos Cluster Boot Loop — Config Drive YAML Parse Error

**Date**: 2026-02-16 through 2026-02-28
**Severity**: Critical — cluster completely unavailable
**Duration**: ~12 days (Feb 16 – Feb 28)
**Status**: Resolved

## Executive Summary

The Talos Kubernetes cluster on OVH bare metal entered an unrecoverable boot loop on Feb 16 after a routine `tofu apply`. The node would boot, read the config drive, and immediately fail with a YAML parse error at line 365. The root cause was **sending `configDriveUserData` as cleartext instead of base64-encoded**. OVH's config drive API processes escape sequences in cleartext input — expanding literal `\n` (backslash-n) into actual newlines — which is documented behavior, not a bug. This broke YAML literal block scalars in the Talos machine configuration. The recommended API usage is to base64-encode the payload, which OVH decodes before writing to disk, bypassing all escape processing.

## Timeline

| Date | Event |
|------|-------|
| Feb 16 | `tofu apply` triggers reinstall with ZFS pool Job template containing `printf '...\n...'` |
| Feb 16 | OVH config drive creation expands `\n` → real newlines, corrupting YAML |
| Feb 16 | Talos enters boot loop: `yaml: line 365: found character that cannot start any token` |
| Feb 16–27 | Multiple `tofu apply` attempts fail — each reinstall recreates the same broken config drive |
| Feb 27 | iKVM console screenshot confirms boot loop with YAML parse error |
| Feb 27 | Rescue mode investigation reveals config drive corruption mechanism |
| Feb 27 | Template fix applied (`printf` → `{ echo; echo; }`) |
| Feb 27 | Config drive manually replaced via rescue mode with correct YAML |
| Feb 28 | Node boots successfully, cluster bootstrapped, all services healthy |

## Root Cause

### Cleartext Mode Escape Processing (Not a Bug)

OVH's dedicated server reinstall API (`POST /dedicated/server/{name}/reinstall`) accepts a `configDriveUserData` field. Per OVH's config drive documentation, this field supports two input modes:

1. **Base64-encoded (recommended)**: OVH base64-decodes the payload and writes the result verbatim to `openstack/latest/user_data` on the config drive. No escape processing occurs.
2. **Cleartext**: OVH processes escape sequences in the input — expanding `\n` to newlines, and potentially other sequences — before writing to the config drive.

**We were using cleartext mode.** Our `main.tf` passed the raw YAML machine configuration directly:

```hcl
config_drive_user_data = data.talos_machine_configuration.controlplane.machine_configuration
```

The comment in `main.tf` incorrectly stated "OVH will base64 encode this automatically, so we pass it as plain text." In reality, OVH **base64-decodes** data it receives (when base64-encoded). It does not auto-encode cleartext input — it processes it with escape expansion.

**This is not an OVH bug** — it is documented behavior. The OVH BYOI guide states the field "accepts a base64-encoded blob (recommended) or cleartext with escaped special characters" and recommends encoding with `base64 -w0`.

### How It Broke the Config

The ZFS pool setup Job template (`templates/zfs-pool-job.yaml.tftpl`) contained:

```bash
printf 'label: gpt\n, , %s\n' "$PART_TYPE" | sfdisk --force --no-reread "$device"
```

This shell script was embedded inside a YAML literal block scalar (`|`) within an `inlineManifests` entry in the Talos machine configuration. In correct YAML, the entire script block maintains consistent indentation (e.g., 14 spaces).

After OVH's cleartext escape processing, the single-line `printf` became:

```
              printf 'label: gpt
, , %s
' "$PART_TYPE" | sfdisk --force --no-reread "$device"
```

The `, , %s` line now starts at **column 0** — outside the indentation level of the YAML literal block scalar. This terminates the block, and the YAML parser attempts to interpret `, , %s` as a YAML token, producing:

```
yaml: line 365: found character that cannot start any token
```

### Evidence

Comparing the locally-computed config vs. the config drive content:

| Property | Local (correct) | Config drive (broken) |
|----------|----------------|----------------------|
| Lines | 409 | 410 |
| Bytes | 25,883 | 25,880 |
| YAML documents | 4 | 4 (but malformed) |
| Non-ASCII chars | 0 | 0 |

The 3-byte difference: two `\n` sequences (2×2 chars = 4 bytes) expanded to two newlines (2×1 byte = 2 bytes), minus 1 byte from a trailing newline difference = net -3 bytes, but +1 line from the expansion.

## What Was Tried

### Attempts That Did Not Work

1. **Multiple `tofu apply` reinstalls** (Feb 16–27)
   - Each reinstall triggered OVH to create a fresh config drive, but always with the same escape expansion
   - The template still contained `printf '...\n...'` and we were still using cleartext mode, so every new config drive was identically broken
   - Port 50000 (Talos API) never opened — node stuck in boot loop before reaching API readiness
   - **In hindsight**: even fixing the template wouldn't have been sufficient without either removing all escape sequences OR switching to base64 encoding

2. **Changing `instance-id` in config drive metadata**
   - Hypothesized that OVH might be caching/reusing old config drives
   - Changed from static `var.cluster_name` to `"${var.cluster_name}-${terraform_data.reinstall_trigger.id}"`
   - Investigation via rescue mode proved OVH *does* create new config drives on each reinstall (UUID matched latest reinstall timestamp)
   - The `instance-id` change was not the fix, but was kept for correctness

3. **Upgrading Talos v1.12.0 → v1.12.3**
   - v1.12.3 release notes mentioned "skip empty documents on config decoding"
   - This did not help because the error was a fundamental YAML parse failure, not an empty document issue
   - The upgrade was kept for other benefits

4. **Removing redundant `talos.platform=openstack` kernel arg**
   - Cleaned up the schematic but had no bearing on the YAML parse error

### Diagnosis Path

1. **iKVM console screenshot** (via ovh-ikvm-mcp) — confirmed Talos was booting but failing to parse config
2. **Rescue mode boot** — SSH'd into Debian rescue environment to inspect disks
3. **Config drive mount and inspection** — mounted `/dev/nvme0n1p5`, extracted `user_data`
4. **Line-by-line diff** — identified line 365 as `, , %s` at column 0 (should have been inline with printf)
5. **Hex dump comparison** — confirmed `\n` expansion as the mechanism

## The Fix

### 1. Proper Fix: Base64-Encode Config Drive User Data (See [#147](https://github.com/xd-ventures/tf-xd-venture-talos01/issues/147))

The correct fix is to base64-encode the `configDriveUserData` payload in `main.tf`, matching the OVH-recommended API usage:

```hcl
# BEFORE (cleartext — subject to escape processing):
config_drive_user_data = data.talos_machine_configuration.controlplane.machine_configuration

# AFTER (base64 — written verbatim after OVH decodes):
config_drive_user_data = base64encode(data.talos_machine_configuration.controlplane.machine_configuration)
```

This eliminates the entire class of escape-processing issues — any content in templates (`\n`, `\t`, `\\`, etc.) is preserved exactly as generated. **This fix has not yet been applied** — it requires empirical verification that the Terraform OVH provider correctly passes base64 data to the API without additional encoding, and that Talos reads the decoded `user_data` correctly. Tracked in [#147](https://github.com/xd-ventures/tf-xd-venture-talos01/issues/147).

### 2. Template Workaround (Applied)

As an immediate workaround while still using cleartext mode, replaced `printf` with `echo` commands in `templates/zfs-pool-job.yaml.tftpl` to avoid any `\n` sequences:

**Before:**
```bash
printf 'label: gpt\n, , %s\n' "$PART_TYPE" | sfdisk --force --no-reread "$device"
```

**After:**
```bash
# NOTE: Use { echo; echo; } instead of printf with \n to avoid
# OVH config drive cleartext escape processing that expands \n into real newlines,
# breaking the YAML literal block scalar in inlineManifests.
{ echo "label: gpt"; echo ", , $PART_TYPE"; } | sfdisk --force --no-reread "$device"
```

**Limitation**: This workaround is fragile — any future template that introduces `\n`, `\t`, or other escape sequences will trigger the same failure. The base64 fix (above) is the proper long-term solution.

### 2. Config Drive Manual Replacement (One-Time Recovery)

Since `tofu apply` could not fix the running system (the node never booted far enough to accept API calls), the config drive was manually replaced via OVH rescue mode:

1. Boot into rescue mode (bootId 230242)
2. Set rescue SSH key via OVH API (`PUT /dedicated/server/{name}` with `rescueSshKey`)
3. SSH into rescue environment
4. Generate correct config locally with the template fix applied
5. Create new ISO: `genisoimage -V "config-2" -R -J -o /tmp/config.iso /tmp/config-2/`
6. Write to partition: `dd if=/tmp/config.iso of=/dev/nvme0n1p5 bs=1M`
7. Set boot back to disk, reboot

### 3. Post-Boot Tailscale Recovery

After the node booted successfully, the Tailscale auth key in the config drive had expired (keys are valid for 1 hour). Recovery required:

1. Taint the `tailscale_tailnet_key.talos[0]` resource
2. `tofu apply` to generate a fresh key
3. Immediately apply the new config to the running node via `talosctl apply-config --mode no-reboot`
4. This had to be done quickly (within the 1-hour key expiry window)
5. Required 3 attempts — first two keys expired before Tailscale could authenticate

## Other Issues Encountered During Recovery

### OVH API v2 Field Names

The reinstall API requires **camelCase** field names (`imageURL`, `configDriveUserData`, `operatingSystem`), not snake_case. Using snake_case returns `400 Bad Request: Unknown parameter`.

### OVH API Permission Scope

API credentials with `/dedicated/server/*` do **not** cover `/dedicated/server` (the list endpoint). The wildcard requires at least one character after the slash. Direct server paths like `/dedicated/server/<server-name>/...` work.

### MCP Server Timeout

The ovh-ikvm-mcp server's default Bun.serve idle timeout of 10s was too short for KVM screenshot capture (30-60s). Fixed by adding `idleTimeout: 255` to the server config.

### ts.net DNS Resolution on Node

The Talos node cannot resolve its own `*.ts.net` hostname via MagicDNS internally. This means `talosctl health` fails with DNS errors when the cluster endpoint uses ts.net, but `kubectl` works fine from external machines with Tailscale. This is a known limitation, documented in `talos.tf`.

## Changes Made

| File | Change | Purpose |
|------|--------|---------|
| `templates/zfs-pool-job.yaml.tftpl` | `printf '\n'` → `{ echo; echo; }` | Workaround: avoid `\n` in cleartext mode |
| `talos.tf` | Remove `talos.platform=openstack` from extraKernelArgs | Remove redundant arg (platform set via image factory) |
| `terraform.tfvars` | `talos_version` v1.12.0 → v1.12.3 | Latest patch release |
| `main.tf` | Dynamic `instance-id` in config drive metadata | Unique ID per reinstall |
| `tailscale.tf` | Direct key reference (remove proxy pattern) | Fix stale key reads (issue #129) |

## Outstanding Action Items

| File | Change Needed | Purpose |
|------|--------------|---------|
| `main.tf` | `config_drive_user_data = base64encode(...)` | Proper fix: bypass cleartext escape processing |
| `main.tf` | Fix comment on line 110 ("OVH will base64 encode this automatically") | Comment is factually wrong — OVH base64-decodes, not encodes |

## Lessons Learned

1. **Always base64-encode `configDriveUserData`.** OVH's API processes escape sequences in cleartext input. Base64 encoding is the documented recommended approach and eliminates the entire class of escape-expansion issues. The incorrect assumption that "OVH auto-encodes" led to 12 days of downtime.

2. **Read the vendor's config drive documentation before implementing.** The OVH BYOI guide clearly states the recommended encoding and the cleartext behavior. This would have prevented the issue entirely.

3. **Config drive content should be validated before reinstall.** A pre-apply check that renders the full config and runs it through a YAML parser would have caught this immediately, regardless of encoding mode.

4. **iKVM/IPMI console access is essential for bare metal debugging.** Without the MCP-based screenshot tool, diagnosing a boot loop on a headless server would have required OVH support intervention.

5. **Rescue mode is the escape hatch for config drive issues.** When the node can't boot far enough to accept API calls, rescue mode + manual config drive replacement is the only path.

6. **Tailscale auth key timing is fragile during recovery.** The 1-hour key expiry creates a tight window. Consider using reusable keys for disaster recovery scenarios, or extending the expiry for initial setup.

## Incorrect Assumptions

| Assumption | Reality |
|-----------|---------|
| "OVH will base64 encode this automatically" (main.tf comment) | OVH base64-**decodes** data you send. It does not auto-encode cleartext. |
| "OVH expands `\n` — this is a bug" | This is documented behavior for cleartext mode. Base64 mode bypasses it. |
| "Avoiding `\n` in templates is a permanent fix" | It's a fragile workaround. Any future `\n`, `\t`, or `\\` in templates could re-trigger the issue. |

## Prevention

- [ ] **Switch to base64 encoding** in `main.tf`: `config_drive_user_data = base64encode(...)` — eliminates the root cause
- [ ] **Fix the misleading comment** in `main.tf` (line 110) that says "OVH will base64 encode this automatically"
- [ ] Add a CI check that renders all templates and validates the resulting YAML
- [ ] Keep rescue mode procedures documented for future incidents
- [ ] Document the cleartext escape behavior in project knowledge base (done in MEMORY.md)
