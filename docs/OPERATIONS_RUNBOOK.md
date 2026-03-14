# Operations Runbook

Step-by-step procedures for common operational tasks on the Talos Kubernetes cluster.

## Talos Version Upgrade

Version upgrades trigger a full OVH BYOI reinstall via `tofu apply`. This wipes the disk
including etcd state and ZFS pools. Expected downtime: 15–30 minutes. Workloads redeploy
automatically via ArgoCD.

See [ADR-0012](adr/0012-single-node-destructive-upgrades.md) for rationale on destructive
upgrades and the multi-node upgrade path.

### Pre-Checks

1. **Verify current cluster health**
   ```bash
   export TALOSCONFIG=$PWD/talosconfig
   talosctl health --wait-timeout 2m
   kubectl get nodes -o wide
   kubectl get pods -A --field-selector status.phase!=Running,status.phase!=Succeeded
   ```

2. **Check ZFS pool status** (if enabled)
   ```bash
   talosctl -n $(talosctl config info -o json | jq -r '.endpoints[0]') \
     run /usr/local/sbin/zpool status
   ```

3. **Back up persistent data** — ZFS pools do not survive reinstall.
   Export any data you need before proceeding.

4. **Verify Tailscale connectivity**
   ```bash
   tailscale status | grep $(tofu output -raw tailscale_hostname | cut -d. -f1)
   tailscale ping $(tofu output -raw tailscale_hostname)
   ```

5. **Review the Talos release notes** for the target version at
   <https://www.talos.dev/latest/introduction/what-is-new/>

### Apply the Upgrade

```bash
# 1. Update talos_version in terraform.tfvars
#    talos_version = "v1.13.0"

# 2. Validate
tofu validate && tflint

# 3. Plan — review the changes carefully
tofu plan

# 4. Apply — triggers reinstall
tofu apply
```

### Post-Verification

1. **Wait for Tailscale device to appear** (~3–5 minutes after reinstall completes)
   ```bash
   tailscale status | grep $(tofu output -raw tailscale_hostname | cut -d. -f1)
   ```

2. **Verify Talos version**
   ```bash
   talosctl version
   ```

3. **Check cluster health**
   ```bash
   talosctl health --wait-timeout 5m
   kubectl get nodes -o wide
   kubectl get pods -A
   ```

4. **Verify Cilium CNI**
   ```bash
   cilium status
   hubble status
   ```

5. **Verify ZFS pool** (if enabled) — the pool must be recreated after reinstall
   ```bash
   kubectl logs -n kube-system job/zfs-pool-setup
   talosctl run /usr/local/sbin/zpool status
   ```

### Rollback

If the upgrade fails:

1. **Revert `talos_version`** in `terraform.tfvars` to the previous version.
2. **Re-apply** to reinstall with the previous version:
   ```bash
   tofu apply
   ```
3. If the server is unreachable, see [Failure Recovery](#failure-recovery) below.

### Non-Destructive Upgrade Alternative

For upgrades that preserve etcd state and ZFS pools, use `talosctl upgrade` directly
instead of `tofu apply`. This only replaces the Talos OS image without triggering
a full reinstall:

```bash
talosctl upgrade --image $(tofu output -raw talos_installer_image)
```

> **Caution**: The Terraform state will not reflect the new version. Run `tofu plan`
> afterward to check for drift. See [ADR-0012](adr/0012-single-node-destructive-upgrades.md)
> for detailed guidance on when to use each approach.

---

## Failure Recovery

### Node Unresponsive (Tailscale + Public IP Both Down)

1. **Check server status via OVH API**
   ```bash
   ./scripts/ovh-server-status.sh
   ```

2. **Capture console screenshot via iKVM** (if [ovh-ikvm-mcp](https://github.com/xd-ventures/ovh-ikvm-mcp) is running)
   ```bash
   # Use the MCP get_screenshot tool with the server ID from list_servers
   # Or access the iKVM console directly via OVH Manager → IPMI → KVM
   ```

3. **Request IPMI console access**
   ```bash
   ./scripts/ovh-ipmi-access.sh
   ```

4. **If server is in a boot loop, boot to rescue mode**
   ```bash
   ./scripts/ovh-rescue-boot.sh
   # SSH to rescue (credentials in OVH manager)
   ssh root@<server-public-ip>
   ```

5. **Inspect disks in rescue mode**
   ```bash
   lsblk
   mount /dev/nvme0n1p5 /mnt   # STATE partition
   cat /mnt/config.yaml         # Inspect Talos config
   ```

6. **Return to normal boot when ready**
   ```bash
   ./scripts/ovh-normal-boot.sh
   ```

7. **If unrecoverable, reinstall from scratch**
   ```bash
   tofu apply -replace='terraform_data.reinstall'
   ```

### Tailscale Connection Lost (Server Running)

1. **Try the public IP** (only works if firewall is disabled)
   ```bash
   talosctl --endpoints <public-ip> version --insecure
   ```

2. **Check Tailscale device status**
   ```bash
   tailscale status
   ```

3. **Force a new Tailscale auth key** (the existing key may be expired/consumed)
   ```bash
   tofu taint 'tailscale_tailnet_key.talos[0]'
   tofu apply
   ```

4. **If the firewall is blocking and Tailscale is down** — you are locked out.
   Use iKVM/IPMI console or rescue mode to diagnose.
   See [ADR-0005](adr/0005-remote-access.md) for the access model.

### ZFS Pool Degraded

1. **Check pool status**
   ```bash
   talosctl run /usr/local/sbin/zpool status tank
   ```

2. **If a disk has failed**, the mirror continues serving from the remaining disk.
   Check which disk is faulted:
   ```bash
   talosctl run /usr/local/sbin/zpool status -v tank
   ```

3. **Replace the failed disk** (requires physical intervention or OVH support ticket).
   After replacement, identify devices using `zpool status -v tank` output and `lsblk`:
   ```bash
   # Example: /dev/nvme0n1p3 failed, replaced disk appears as /dev/nvme1n1
   # Partition the new disk, then replace the faulted vdev
   talosctl run /usr/local/sbin/zpool replace tank /dev/nvme0n1p3 /dev/nvme1n1p3
   ```

4. **Monitor resilver progress**
   ```bash
   talosctl run /usr/local/sbin/zpool status tank
   ```

### ZFS Pool Not Mounting After Reinstall

1. **Check the setup job logs**
   ```bash
   kubectl logs -n kube-system job/zfs-pool-setup
   ```

2. **Verify the ZFS extension is loaded**
   ```bash
   talosctl run lsmod | grep zfs
   ```

3. **Manually import the pool** (if it exists from a previous install)
   ```bash
   talosctl run /usr/local/sbin/zpool import tank
   ```

---

## Operational Cadence

### Daily Checks

| Check | Command | What to Look For |
|-------|---------|------------------|
| Node status | `kubectl get nodes` | `Ready` status |
| Pod health | `kubectl get pods -A --field-selector status.phase!=Running,status.phase!=Succeeded` | No stuck pods |
| Tailscale connectivity | `tailscale ping <hostname>` | Successful ping |

### Weekly Checks

| Check | Command | What to Look For |
|-------|---------|------------------|
| ZFS pool health | `talosctl run /usr/local/sbin/zpool status` | `ONLINE`, no errors |
| Disk usage | `kubectl top nodes` | No resource pressure |
| Cilium status | `cilium status` | All components healthy |
| Hubble flows | `hubble status` | Relay connected |
| Talos services | `talosctl service` | All services running |
| OVH server status | `./scripts/ovh-server-status.sh` | State `ok` |
| Pending upgrades | Check [Talos releases](https://github.com/siderolabs/talos/releases) | Review changelogs |

### Monthly Checks

| Check | Action |
|-------|--------|
| Credential expiry | Review OVH API token expiry, Tailscale OAuth client status |
| Security advisories | Check Talos, Cilium, and Kubernetes CVEs |
| Backup verification | Confirm persistent data backups are current |
| Resource usage trends | Review node resource consumption over time |

---

## Common Operations Quick Reference

| Task | Command |
|------|---------|
| Get kubeconfig | `tofu output -raw kubeconfig > kubeconfig && chmod 600 kubeconfig` |
| Get talosconfig | `tofu output -raw talosconfig > talosconfig && chmod 600 talosconfig` |
| Check server status | `./scripts/ovh-server-status.sh` |
| Boot to rescue mode | `./scripts/ovh-rescue-boot.sh` |
| Return to normal boot | `./scripts/ovh-normal-boot.sh` |
| Request IPMI access | `./scripts/ovh-ipmi-access.sh` |
| Force reinstall | `tofu apply -replace='terraform_data.reinstall'` |
| Validate config | `tofu validate && tflint` |
| Run all pre-commit checks | `pre-commit run --all-files` |

## Related Documents

- [Architecture Overview](ARCHITECTURE.md) — system design and component details
- [Testing Strategy](TESTING_STRATEGY.md) — validation phases and debugging procedures
- [OVH BYOI Guide](OVH_BYOI_GUIDE.md) — installation specifics
- [ADR-0012: Single-Node Upgrades](adr/0012-single-node-destructive-upgrades.md) — upgrade strategy rationale
