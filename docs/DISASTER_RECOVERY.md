# Disaster Recovery Runbook

Step-by-step recovery procedures for each failure mode in the Talos cluster.

## Scenario 1: OVH Reinstall Fails

The `ovh_dedicated_server_reinstall_task` resource may fail due to OVH API
transient errors, timeouts, or infrastructure issues on OVH's side.

### Symptoms

- `tofu apply` fails during the reinstall task with an OVH API error
- The OVH task shows status `error` or `cancelled` in the OVH Manager

### Recovery

1. **Check the OVH task status** — the reinstall may have partially completed:
   ```bash
   ./scripts/ovh-server-status.sh
   ```

2. **Retry via Terraform** — transient errors often resolve on retry:
   ```bash
   tofu apply -replace='ovh_dedicated_server_reinstall_task.talos'
   ```

3. **If retries fail, reinstall manually via the OVH Python SDK**:
   ```python
   import ovh
   client = ovh.Client()  # reads OVH_* env vars

   result = client.post(
       f'/dedicated/server/{service_name}/reinstall',
       operatingSystem='byoi_64',
       customizations={
           'hostname': 'talos-cluster',
           'imageURL': '<talos-image-url>',
           'imageType': 'qcow2',
           'efiBootloaderPath': '\\EFI\\BOOT\\BOOTX64.EFI',
           'configDriveUserData': '<base64-encoded-machine-config>',
           'configDriveMetadata': {
               'instance-id': '<unique-id>',
               'local-hostname': 'talos-cluster',
           },
       }
   )
   task_id = result['taskId']
   ```

   Then monitor the task:
   ```bash
   ./scripts/ovh-wait-task.sh <task_id>
   ```

4. **After manual reinstall, reconcile state**:
   ```bash
   tofu state rm ovh_dedicated_server_reinstall_task.talos
   tofu apply
   ```

---

## Scenario 2: Tailscale Key Expired or Consumed

The Tailscale auth key is single-use (`TS_AUTH_ONCE=true`) and expires after 1 hour.
If a reinstall is needed and the key has already been consumed:

### Symptoms

- `tofu plan` shows the key resource needs recreation
- Precondition error: "Tailscale is enabled but auth key is empty"

### Recovery

```bash
# Force a new auth key
tofu taint 'tailscale_tailnet_key.talos[0]'

# Re-apply — generates fresh key and triggers reinstall
tofu apply
```

If the Tailscale device already exists from a previous install:

```bash
# Clean up stale devices manually
python3 scripts/tailscale-device-cleanup.py
# (Set TS_CLEANUP_HOSTNAME=<hostname> and TAILSCALE_OAUTH_CLIENT_ID/SECRET)
```

---

## Scenario 3: Server Unreachable (Public IP + Tailscale Both Down)

The server is unresponsive on both the public IP and Tailscale. This typically
indicates a boot failure, kernel panic, or misconfigured networking/firewall.

### Step 1: Check Server Status

```bash
./scripts/ovh-server-status.sh
```

If the server state is `ok`, it may be booted but network-isolated.

### Step 2: Capture Console Screenshot (iKVM)

If the [ovh-ikvm-mcp](https://github.com/xd-ventures/ovh-ikvm-mcp) server is running:

```bash
# Use the MCP get_screenshot tool with the server ID from list_servers
# Or access the iKVM console directly via OVH Manager → IPMI → KVM
```

### Step 3: Request IPMI Console Access

```bash
./scripts/ovh-ipmi-access.sh
```

This provides a temporary KVM-over-IP session to see the physical console.

### Step 4: Boot to Rescue Mode

If the server is stuck in a boot loop or has an unrecoverable OS issue:

```bash
./scripts/ovh-rescue-boot.sh
```

Wait for the rescue mode credentials (displayed in the OVH Manager), then SSH in:

```bash
ssh root@<server-public-ip>
```

### Step 5: Inspect in Rescue Mode

```bash
# Check disk layout — identify partitions before mounting
lsblk
fdisk -l

# Mount Talos STATE partition (verify partition with lsblk/blkid first)
# On this server: nvme0n1p5 is typically the STATE partition
mount /dev/nvme0n1p5 /mnt

# Inspect the stored config
cat /mnt/config.yaml

# Check for kernel panic logs
dmesg | tail -100
```

### Step 6: Return to Normal Boot

```bash
./scripts/ovh-normal-boot.sh
```

---

## Scenario 4: State Corruption (Missing Resources)

Terraform state may become inconsistent after a partial failure (e.g., the reinstall
task ran but Terraform crashed before recording it).

### Diagnose State Issues

```bash
# List all resources in state
tofu state list

# Check specific resource
tofu state show ovh_dedicated_server_reinstall_task.talos
```

### Remove Stale Resources

> **CAUTION**: Always back up state before removing resources. State removal is irreversible.

```bash
# Back up current state first
tofu state pull > state-backup.json
```

If a resource exists in state but not in reality:

```bash
tofu state rm ovh_dedicated_server_reinstall_task.talos
```

### Targeted Apply

After cleaning up state, re-apply only the affected resources:

```bash
tofu apply -target=ovh_dedicated_server_reinstall_task.talos
```

### Full State Reconciliation

If multiple resources are out of sync:

```bash
# Plan to see what Terraform thinks needs to change
tofu plan

# Apply with careful review
tofu apply
```

---

## Scenario 5: Config Drive / Boot Failure

The server installs but fails to boot, often due to corrupted config drive content
or an incompatible image.

### Symptoms

- Server stuck at GRUB, kernel panic, or Talos fails to parse machine config
- Console shows YAML parse errors (see [RCA](rca-2026-02-config-drive-yaml-parse.md))

### Diagnose via Console

1. Use iKVM or IPMI to view the physical console
2. Look for YAML parse errors, missing config drive, or kernel panics

### Fix Config Drive in Rescue Mode

```bash
# Boot to rescue
./scripts/ovh-rescue-boot.sh
ssh root@<server-public-ip>

# Find and mount the config drive
./scripts/inspect-config-drive.sh

# Or manually — find the config drive partition (labeled "config-2"):
blkid | grep -i config-2
# Mount the partition identified above (typically nvme0n1p5 or the last partition)
mount /dev/nvme0n1p5 /mnt/config
cat /mnt/config/openstack/latest/user_data
```

If the config is corrupted, the only fix is to reinstall:

```bash
./scripts/ovh-normal-boot.sh
tofu apply -replace='ovh_dedicated_server_reinstall_task.talos'
```

### Prevention

- Config drive user data is base64-encoded to prevent OVH escape processing
  (see [RCA](rca-2026-02-config-drive-yaml-parse.md))
- Template validation runs in CI via `scripts/validate-templates.py`
- Preconditions check for empty auth keys and image URLs before reinstall

---

## Scenario 6: Full Recovery (Bricked to Operational)

End-to-end procedure to recover from a completely non-functional state.

### Prerequisites

- OVH API credentials (environment variables set)
- Tailscale OAuth client credentials
- Access to the Terraform state backend (or local state)
- The current `terraform.tfvars` configuration

### Steps

1. **Assess the situation**
   ```bash
   ./scripts/ovh-server-status.sh
   ```

2. **Clean up Terraform state** (if corrupted)
   ```bash
   tofu state list
   # Remove any resources that are stuck
   tofu state rm ovh_dedicated_server_reinstall_task.talos
   ```

3. **Clean up stale Tailscale devices**
   ```bash
   TS_CLEANUP_HOSTNAME=<hostname> python3 scripts/tailscale-device-cleanup.py
   ```

4. **Force a fresh Tailscale key**
   ```bash
   tofu taint 'tailscale_tailnet_key.talos[0]'
   ```

5. **Trigger full reinstall**
   ```bash
   tofu apply
   ```

6. **Wait for Tailscale device** (~3–5 minutes)
   ```bash
   tailscale status | grep <hostname>
   ```

7. **Verify cluster health**
   ```bash
   tofu output -raw kubeconfig > kubeconfig && chmod 600 kubeconfig
   export KUBECONFIG=$PWD/kubeconfig

   kubectl get nodes
   kubectl get pods -A
   ```

8. **Verify ZFS pool** (if enabled)
   ```bash
   kubectl logs -n kube-system job/zfs-pool-setup
   talosctl run /usr/local/sbin/zpool status
   ```

9. **Restore data** from backups to the new ZFS pool.

---

## IPMI/SOL Access Reference

OVH provides IPMI-based access for out-of-band management:

| Method | Command | Use When |
|--------|---------|----------|
| iKVM console | `./scripts/ovh-ipmi-access.sh` | Visual console needed |
| iKVM screenshot | MCP `get_screenshot` tool | Quick visual check |
| Rescue mode SSH | `./scripts/ovh-rescue-boot.sh` | Disk inspection needed |
| Normal boot restore | `./scripts/ovh-normal-boot.sh` | After rescue diagnosis |

## Talosctl Diagnostic Commands

| Command | Purpose |
|---------|---------|
| `talosctl version` | Verify Talos API is responsive |
| `talosctl health` | Full cluster health check |
| `talosctl service` | List Talos system services |
| `talosctl dmesg` | Kernel messages |
| `talosctl logs kubelet` | Kubelet logs |
| `talosctl logs etcd` | etcd logs |
| `talosctl run /usr/local/sbin/zpool status` | ZFS pool health |

## Related Documents

- [Operations Runbook](OPERATIONS_RUNBOOK.md) — routine operational procedures
- [Testing Strategy](TESTING_STRATEGY.md) — validation phases and debugging
- [Architecture Overview](ARCHITECTURE.md) — failure modes table
- [RCA: Config Drive YAML Parse](rca-2026-02-config-drive-yaml-parse.md) — root cause analysis of the config drive outage
