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

- Precondition error: "Tailscale is enabled but auth key is empty"

> **Note**: `tofu plan` will **not** show the key resource needing recreation — the
> key sets `recreate_if_invalid = "never"` (tailscale.tf) precisely so that hourly
> expiry does not churn plans (#129). An expired key only surfaces via the
> precondition error or a failed device registration after reinstall.

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
# Check disk layout — identify partitions BY LABEL, never by number
lsblk
blkid   # STATE = Talos state partition; config-2 = OVH config drive

# Inspect the machine config delivered by OVH (config drive, label config-2 —
# on this server it has typically been nvme0n1p5, but always verify with blkid)
mount $(blkid -L config-2) /mnt
cat /mnt/openstack/latest/user_data
umount /mnt

# Inspect the config Talos persisted (STATE partition)
mount $(blkid -L STATE) /mnt
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
- Console shows YAML parse errors (see [RCA](incidents/2026-02-config-drive-yaml-parse.md))

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

# Or manually — find and mount the config drive partition by label:
blkid | grep -i config-2
mkdir -p /mnt/config
mount $(blkid -L config-2) /mnt/config
cat /mnt/config/openstack/latest/user_data
```

If the config is corrupted, the only fix is to reinstall:

```bash
./scripts/ovh-normal-boot.sh
tofu apply -replace='ovh_dedicated_server_reinstall_task.talos'
```

### Prevention

- Config drive user data is base64-encoded to prevent OVH escape processing
  (see [RCA](incidents/2026-02-config-drive-yaml-parse.md))
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

8. **Verify ZFS pool** (if enabled) — Talos has no shell, so run `zpool` from a
   privileged debug pod in the host mount namespace:
   ```bash
   kubectl logs -n kube-system job/zfs-pool-setup

   NODE=$(kubectl get nodes -o jsonpath='{.items[0].metadata.name}')
   kubectl debug node/$NODE -it --profile=sysadmin --image=alpine -- \
     nsenter -t 1 -m -- /usr/local/sbin/zpool status
   ```

9. **Restore cluster state and data.** Recover etcd (Scenario 7) so the
   rebuilt node comes back as the same cluster rather than an empty one. See
   [What Is and Isn't Backed Up](#what-is-and-isnt-backed-up) for the ZFS/PV
   data caveat — pool contents are **not** currently recoverable from backup.

---

## What Is and Isn't Backed Up

Restore is only as good as the backup. Know the boundary before you need it.

| Asset | Backed up? | Where | Restore path |
|-------|-----------|-------|--------------|
| **etcd** (cluster state: workloads, secrets, RBAC, CRDs) | ✅ every 6 h | Primary: OVH bucket, `<cluster_name>/` prefix (zstd + age). Offsite: B2 `etcd/` (daily copy) | Scenario 7 |
| **Talos machine secrets** (PKI, etcd/k8s CA) | ✅ (inside OpenTofu state) | OpenTofu state → offsite config bundle `config/<date>/config-bundle.tar.gz.age` | Scenario 8 |
| **OpenTofu state, `terraform.tfvars`, `backend.tfvars`** | ✅ daily | Offsite config bundle | Scenario 8 |
| **Repo / machine config source** | ✅ daily (git bundle) | Offsite config bundle (`repo.bundle`) | Scenario 8 |
| **Workloads / add-ons** | ⤴️ rebuilt from Git (not backed up as data) | Git (ArgoCD app-of-apps once #319 lands) | GitOps re-sync |
| **PV / ZFS dataset *contents*** | ❌ **NOT YET** | — | **Gap — see below** |

> **⚠️ Known gap — persistent-volume data is not backed up.** The ZFS mirror
> pool (`tank`) is *recreated* on recovery (empty) by the `zfs-pool-setup` Job,
> but nothing today snapshots or ships its **contents**. The backup *approach*
> (ZFS `zfs send` streams vs a PV/application-level tool such as Velero, vs a
> storage-native backup target) is an **open decision**, deliberately coupled to
> the distributed-storage architecture — tracked in **#361**. Until it ships,
> treat any data that only lives on a PV as **non-durable**: anything you cannot
> afford to lose must be reconstructable from Git or an external source. The
> etcd + config-bundle backups fully cover *cluster state and identity*; they do
> not cover *application data at rest*.

The keys that decrypt the backups live in operator custody (password manager +
offline media, ADR-0018 decision 4), **never** in state, CI, or this repo:
- `AGE_SECRET_KEY` — decrypts the **etcd** snapshots (pairs with
  `talos_backup_age_public_key`).
- The **offsite** config-bundle age identity — decrypts the config bundle
  (pairs with the `OFFSITE_AGE_PUBKEY` secret).

These may be two different age identities. A restore drill that cannot find
both keys has found a real gap — that is the point of drilling.

---

## Scenario 7: etcd Snapshot Restore (Recover the Control Plane)

Use this when etcd is corrupted or lost but you want the cluster back as
**itself** — same secrets, same workloads — rather than a fresh install. This
is the single most important recovery path; it is the first drilled procedure
(ADR-0018 decision 5a).

> Snapshots are taken through the Talos API (`talos-backup` → `EtcdSnapshot`),
> so they **carry the etcd integrity hash** — restore does **not** need
> `--recover-skip-hash-check`. That flag is only for snapshots copied raw out of
> `/var/lib/etcd` with `talosctl cp`.

### Step 1: Fetch keys and the node endpoint

```bash
# age identity for etcd snapshots — from custody, kept in the shell only.
export AGE_SECRET_KEY='AGE-SECRET-KEY-1...'

# Node API endpoint + talosconfig (identifiers are not committed — read them
# from outputs, never hardcode them in a public doc). talosctl reaches the node
# over Tailscale, so use its Tailscale IP.
export TALOSCONFIG=$PWD/talosconfig
tofu -chdir=infra output -raw talosconfig > "$TALOSCONFIG"
NODE_IP=$(tofu -chdir=infra output -raw tailscale_device_ip)
```

### Step 2: Download the latest snapshot

Primary (OVH) — read with the **talos-backup writer** credential that owns the
objects (OVH per-object ownership blocks other users):

```bash
# talos-backup writer creds — the identity that OWNS the snapshot objects. They
# are embedded in this sensitive output (which also builds the in-cluster secret):
#   tofu -chdir=infra output -raw talos_backup_secret_command
export AWS_ACCESS_KEY_ID='<from talos_backup_secret_command>'
export AWS_SECRET_ACCESS_KEY='<from talos_backup_secret_command>'

REGION=$(tofu -chdir=infra output -json talos_backup_info | jq -r .region)   # e.g. gra
OVH_S3="https://s3.${REGION}.io.cloud.ovh.net"
BUCKET='<talos_backup_s3_bucket, from terraform.tfvars>'        # not an output (identifier, #300)

# Newest object under the cluster prefix (<cluster_name>/, from terraform.tfvars):
LATEST=$(aws --endpoint-url "$OVH_S3" s3api list-objects-v2 --bucket "$BUCKET" \
  --prefix '<cluster_name>/' \
  --query 'sort_by(Contents,&LastModified)[-1].Key' --output text)
aws --endpoint-url "$OVH_S3" s3 cp "s3://$BUCKET/$LATEST" snapshot.zst.age
```

If OVH itself is gone, pull from the offsite B2 copy instead (`etcd/` prefix,
using the B2 read credentials from custody) — this is the Scenario 8 entry point.

### Step 3: Decrypt and decompress to a raw etcd snapshot

```bash
# age identity stays in memory (process substitution), never on disk.
age -d -i <(printf '%s\n' "$AGE_SECRET_KEY") -o snapshot.zst snapshot.zst.age
zstd -d snapshot.zst -o db.snapshot
# db.snapshot is now the raw etcd snapshot (carries its integrity hash).
```

### Step 4: Wipe etcd on the node (only if recovering in place)

Skip this if the node was just freshly reinstalled (etcd is already empty).
Otherwise wipe the ephemeral data so etcd starts clean:

```bash
talosctl -n "$NODE_IP" reset --graceful=false --reboot --system-labels-to-wipe=EPHEMERAL
```

> This wipes the **EPHEMERAL** partition (etcd + container state). The ZFS
> `tank` pool lives on separate disks and **survives** this reset; the persisted
> machine config on the STATE partition also survives. Wait until etcd reports
> `STATE: Preparing` before continuing:

```bash
talosctl -n "$NODE_IP" service etcd     # STATE must read: Preparing
```

### Step 5: Bootstrap from the snapshot

```bash
talosctl -n "$NODE_IP" bootstrap --recover-from=./db.snapshot
```

### Step 6: Verify

```bash
talosctl -n "$NODE_IP" health
tofu -chdir=infra output -raw kubeconfig > kubeconfig && chmod 600 kubeconfig
export KUBECONFIG=$PWD/kubeconfig
kubectl get nodes
kubectl get pods -A          # workloads should be present from the restored state
```

### Multi-node note (future topology)

Today the cluster is a single control-plane node, so the above *is* the whole
procedure. Under the future 3-node topology (ADR-0017), recover by resetting the
other control-plane members, running `bootstrap --recover-from` on **one** node,
and letting the others rejoin automatically once the control-plane endpoint is
back (ADR-0018 decision 5b).

---

## Scenario 8: Full-Loss Recovery from the Off-Provider Copy (OVH Gone)

The "OVH account/region is gone, all we have is B2 + the custody keys" path —
RTO target ≤ 1 working day (ADR-0018 decision 9). Everything needed is in the
B2 bucket and the two age identities.

### Step 1: Retrieve from custody

- B2 **read** credentials (key id + application key).
- The **offsite** config-bundle age identity.
- The **etcd** `AGE_SECRET_KEY`.

### Step 2: Recover the config bundle (state, tfvars, repo)

```bash
# Configure an rclone 'b2' remote (see .github/workflows/offsite-backup.yml for
# the exact shape; upload_cutoff=0 only matters for writes, not reads).
LATEST_DAY=$(rclone lsf b2:<bucket>/config/ | sort | tail -1)   # newest date dir
rclone copyto "b2:<bucket>/config/${LATEST_DAY}config-bundle.tar.gz.age" bundle.age
age -d -i <(printf '%s\n' "$OFFSITE_AGE_IDENTITY") -o bundle.tar.gz bundle.age
mkdir recover && tar -xzf bundle.tar.gz -C recover
# recover/ now holds: terraform.tfstate  terraform.tfvars  backend.tfvars  repo.bundle
```

### Step 3: Rebuild the repo and infrastructure

```bash
git clone recover/repo.bundle src && cd src
cp ../recover/terraform.tfvars ../recover/backend.tfvars infra/
# Point OpenTofu at the recovered state (new backend bucket, or local):
tofu -chdir=infra init -backend=false
cp ../recover/terraform.tfstate infra/terraform.tfstate
# Provision a replacement server (OVH again, or the VM module for another provider):
tofu -chdir=infra plan      # review carefully before applying to new infra
tofu -chdir=infra apply
```

The machine config (including the Talos PKI / etcd CA) is reconstructed from the
recovered state, so the new node is cryptographically the **same** cluster.

### Step 4: Restore etcd, re-establish GitOps

1. Restore etcd onto the new node via **Scenario 7**, using the newest snapshot
   from B2 `etcd/` (decrypt with the etcd `AGE_SECRET_KEY`).
2. Re-establish GitOps (ArgoCD app-of-apps, once #319 lands) so workloads
   re-render from Git.
3. **PV/ZFS data does not come back** — the pool is recreated empty (see the
   [known gap](#what-is-and-isnt-backed-up)).

---

## Restore Drills

> *A backup that has not restored is a hypothesis.* Drilling is what turns it
> into a recovery capability (ADR-0018 decision 5).

**Cadence**
- **Quarterly** — Scenario 7 (etcd restore) into an isolated scratch cluster.
- **At least annually** — Scenario 8 (full-loss recovery from the off-provider
  copy alone).

**Drill prerequisites** — a full cloud drill is **operator-in-the-loop**: the CI
automation deliberately cannot self-serve these (surfaced by drill #1). Gather
them before starting:
- The **age identity** that decrypts the snapshots — from custody, held **in
  memory only** (ADR-0018 decisions 4 & 5).
- **OpenStack / OVH Public Cloud credentials** (`OS_*`) to stand up the ephemeral
  scratch VM.
- The **machine secrets** (from OpenTofu state / the config bundle) if the drill
  must reproduce cluster *identity* — a bare `bootstrap --recover-from` on a node
  with *different* secrets restores the **data** but not the same cluster
  identity.

**Drill safety rules** (ADR-0018 decision 5):
- Run in an **isolated scratch environment** (e.g. an ephemeral OVH Public Cloud
  VM), **never** the live cluster or the e2e project.
- Keep the age identity **in memory only** for the duration of the drill.
- **Crypto-shred** the scratch environment on teardown (destroy the VM; do not
  leave decrypted snapshots or keys on disk).
- Record timing and any gaps found — a drill that finds nothing usually means it
  wasn't exercised hard enough.

**Drill log**

| Date | Scenario | Environment | Result | Time to restore | Gaps found |
|------|----------|-------------|--------|-----------------|------------|
| 2026-07-11 | 7 (etcd) — mechanism | local `etcd` container (isolated scratch) | ✅ mechanism + data validated | ~3 min (restore sub-second) | full `bootstrap --recover-from` into a node still pending; needs operator age key + PCI creds — [report](https://github.com/xd-ventures/tf-xd-venture-talos01/issues/318#issuecomment-4948945642) |
| _pending_ | 7 (etcd) — full | ephemeral OVH PCI VM | — | — | bootstrap-into-node rehearsal; best after #319 (render-from-Git) |

---

## IPMI/SOL Access Reference

OVH provides IPMI-based access for out-of-band management:

| Method | Command | Use When |
|--------|---------|----------|
| iKVM console | `./scripts/ovh-ipmi-access.sh` | Visual console needed |
| iKVM screenshot | MCP `get_screenshot` tool | Quick visual check |
| Rescue mode SSH | `./scripts/ovh-rescue-boot.sh` | Disk inspection needed |
| Normal boot restore | `./scripts/ovh-normal-boot.sh` | After rescue diagnosis |

## Diagnostic Commands

| Command | Purpose |
|---------|---------|
| `talosctl version` | Verify Talos API is responsive |
| `talosctl health` | Full cluster health check |
| `talosctl service` | List Talos system services |
| `talosctl dmesg` | Kernel messages |
| `talosctl logs kubelet` | Kubelet logs |
| `talosctl logs etcd` | etcd logs |
| `talosctl read /proc/modules` | Loaded kernel modules (ZFS extension check) |
| `kubectl debug node/$NODE -it --profile=sysadmin --image=alpine -- nsenter -t 1 -m -- /usr/local/sbin/zpool status` | ZFS pool health (Talos has no shell — `talosctl` cannot run host binaries) |

## Related Documents

- [ADR-0018: Backup, Restore & Disaster Recovery](adr/0018-backup-restore-and-disaster-recovery.md) — the decisions behind Scenarios 7–8 and the drill cadence
- [Operations Runbook](OPERATIONS_RUNBOOK.md) — routine operational procedures
- [Testing Strategy](TESTING_STRATEGY.md) — validation phases and debugging
- [Architecture Overview](ARCHITECTURE.md) — failure modes table
- [RCA: Config Drive YAML Parse](incidents/2026-02-config-drive-yaml-parse.md) — root cause analysis of the config drive outage
