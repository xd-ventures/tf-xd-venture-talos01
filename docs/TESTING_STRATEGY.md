# Testing and Validation Strategy

This document describes the automated testing and validation approach for the Talos cluster deployment.

## Overview

The testing strategy enables **autonomous debugging** without requiring manual iKVM console access. It uses:
- OVH CLI/API for server management
- Serial console output capture
- Rescue mode SSH access for deep inspection
- Automated health checks

## Prerequisites

### OVH API Credentials
```bash
# Create application at: https://eu.api.ovh.com/createApp/
export OVH_ENDPOINT="ovh-eu"
export OVH_APPLICATION_KEY="your_app_key"
export OVH_APPLICATION_SECRET="your_app_secret"
export OVH_CONSUMER_KEY="your_consumer_key"
```

### Tools Required
```bash
# OVH CLI
brew install --cask ovh/tap/ovhcloud-cli

# Python OVH SDK (for scripts)
pip install ovh

# Tailscale CLI
brew install tailscale
```

## Validation Phases

### Phase 1: Pre-Deployment Validation

| Check | Command | Expected |
|-------|---------|----------|
| OVH API connectivity | `ovhcloud baremetal list` | Server listed |
| Server state | `scripts/ovh-server-status.sh` | `ok` |
| Terraform syntax | `tofu validate` | Valid |
| Terraform plan | `tofu plan` | No errors |

### Phase 2: Deployment Monitoring

| Check | Tool | Expected |
|-------|------|----------|
| Reinstall task status | OVH API polling | `done` |
| Boot progress | Serial console | Kernel loaded |
| Talos API ready | `talosctl version` | Version returned |
| Tailscale online | Tailscale admin | Device appears |

### Phase 3: Post-Deployment Validation

| Check | Command | Expected |
|-------|---------|----------|
| Talos health | `talosctl health` | All checks pass |
| Kubernetes API | `kubectl get nodes` | Node Ready |
| Cilium status | `cilium status` | OK |
| Hubble status | `hubble status` | OK |
| ZFS pool | `make test-storage` | Pool healthy |

Or run the whole suite: `make test` (TAP output via `scripts/cluster_checks.py`).

## Autonomous Debugging Capabilities

### 1. Server State Monitoring
```bash
# Check server status
./scripts/ovh-server-status.sh

# Monitor reinstall task
./scripts/ovh-wait-task.sh <task_id>
```

### 2. Serial Console Access

OVH provides IPMI-based serial console. To enable boot output on serial:

```yaml
# Add to machine config
machine:
  install:
    extraKernelArgs:
      - console=tty0
      - console=ttyS0,115200n8
```

Access via OVH API:
```bash
# Request IPMI access
./scripts/ovh-ipmi-access.sh

# Capture boot output (requires ovh-kvm tool)
# https://github.com/amilabs/ovh-kvm
```

### 3. Rescue Mode for Deep Inspection

When the server is unresponsive:

```bash
# Boot into rescue mode
./scripts/ovh-rescue-boot.sh

# SSH to rescue environment
ssh root@<server-ip>

# Inspect disks
lsblk
fdisk -l

# Mount and inspect Talos partitions — identify by label, not number
blkid   # STATE = Talos state; config-2 = OVH config drive
mount $(blkid -L STATE) /mnt
ls /mnt

# Check Talos config
cat /mnt/config.yaml

# Inspect ZFS pools (if mdadm/zfs available in rescue)
zpool import -f tank
zpool status
```

### 4. Task Status Polling
```bash
# Monitor OVH task until completion
./scripts/ovh-wait-task.sh <task_id>

# Returns:
# - "done" on success
# - "error" with details on failure
```

## Error Recovery Procedures

### Scenario: Server Stuck in Boot Loop

1. **Check task status**
   ```bash
   ./scripts/ovh-server-status.sh
   ```

2. **Request IPMI access for serial console**
   ```bash
   ./scripts/ovh-ipmi-access.sh
   ```

3. **If needed, boot to rescue mode**
   ```bash
   ./scripts/ovh-rescue-boot.sh
   ```

4. **SSH to rescue and inspect**
   ```bash
   ssh root@<server-ip>
   journalctl -xb  # If available
   dmesg | tail -100
   ```

### Scenario: Talos API Unreachable

1. **Check server is running**
   ```bash
   ./scripts/ovh-server-status.sh
   ```

2. **Check Tailscale device status**
   ```bash
   tailscale status | grep <hostname>
   ```

3. **Try public IP (if firewall disabled)**
   ```bash
   talosctl --endpoints <public-ip> version --insecure
   ```

4. **If all fails, boot rescue and check config**

### Scenario: ZFS Pool Not Mounting

Talos has no shell and `talosctl` cannot run host binaries — use a privileged debug
pod in the host mount namespace (see the Operations Runbook, "Running Host Commands"):

1. **Check pool status**
   ```bash
   NODE=$(kubectl get nodes -o jsonpath='{.items[0].metadata.name}')
   kubectl debug node/$NODE -it --profile=sysadmin --image=alpine -- \
     nsenter -t 1 -m -- /usr/local/sbin/zpool status
   ```

2. **Check ZFS module loaded**
   ```bash
   talosctl -n <tailscale-ip> read /proc/modules | grep -i zfs
   ```

3. **Manually import pool**
   ```bash
   kubectl debug node/$NODE -it --profile=sysadmin --image=alpine -- \
     nsenter -t 1 -m -- /usr/local/sbin/zpool import tank
   ```

## Automated Cluster Checks (In the Repository)

The repository ships a TAP-emitting validation harness: `scripts/cluster_checks.py`
with suite modules under `scripts/checks/`. Run it via Make:

| Target | Coverage |
|--------|----------|
| `make test` | All suites |
| `make test-smoke` | Talos API reachability |
| `make test-config` | Extensions, inline manifests, pods, cluster endpoint |
| `make test-storage` | ZFS pool health, PV write |
| `make test-security` | Firewall port scan |

The same harness runs in CI: `.github/workflows/cluster-checks.yml` executes the smoke
suite daily (cron) against the production cluster and publishes a Job Summary, with
`workflow_dispatch` for on-demand runs of any suite.

**Output redaction**: because the repository is public, CI run logs and Job Summaries
are readable by anyone. The harness therefore redacts live infrastructure identifiers
(endpoints, public/Tailscale IPs, `*.ts.net` hostnames, cluster name, Talos version)
from all TAP output by default, replacing them with placeholders like `[endpoint]` and
`[ipv4]`. For local debugging where the actual values are needed:

```bash
CHECK_REDACT=false make test-smoke
```

Never disable redaction in CI.

## End-to-End Deployment Script (Example)

> **Note**: This script is a reference template — it is not included in the repository.
> Adapt it to your environment before use.

```bash
#!/bin/bash
set -euo pipefail

echo "=== Phase 1: Pre-deployment ==="
tofu validate
tofu plan -out=tfplan

echo "=== Phase 2: Deploy ==="
# The ovh_dedicated_server_reinstall_task resource blocks until the OVH
# reinstall completes — no separate task-wait step is needed.
tofu apply tfplan

echo "=== Phase 3: Wait for Tailscale ==="
HOSTNAME=$(tofu output -raw tailscale_hostname)
echo "Waiting for $HOSTNAME to appear on Tailscale..."
for i in {1..60}; do
  if tailscale status | grep -q "$HOSTNAME"; then
    echo "Tailscale connected!"
    break
  fi
  sleep 10
done

echo "=== Phase 4: Health checks ==="
TS_IP=$(tailscale ip -4 "$HOSTNAME" 2>/dev/null || dig +short "$HOSTNAME")

# Talos health
talosctl --endpoints "$TS_IP" --nodes "$TS_IP" health --wait-timeout 5m

# Kubernetes ready
export KUBECONFIG=$(mktemp)
tofu output -raw kubeconfig > "$KUBECONFIG"
kubectl wait --for=condition=Ready nodes --all --timeout=5m

# Cilium status
kubectl -n kube-system wait --for=condition=Ready pods -l k8s-app=cilium --timeout=5m
cilium status

echo "=== All tests passed ==="
```

## CI/CD Integration

Current CI coverage:

| Workflow | Trigger | Coverage |
|----------|---------|----------|
| `pr-validation.yml` | PRs touching `*.tf`, `scripts/`, `templates/`, lint/hook configs | Pre-commit hooks (fmt, validate, tflint, shellcheck, gitleaks, license headers) + Trivy IaC scan |
| `cluster-checks.yml` | Daily cron + manual | Live cluster validation (smoke suite) against production |
| `codeql.yml` | Push/PR to main + weekly cron | Static analysis (Python, Actions) |
| `sbom.yml` | Push to main + releases | SBOM generation + Trivy vulnerability scan |
| `scorecard.yml` | Weekly + push to main | OpenSSF Scorecard supply-chain posture |

### Full Deployment Testing (Planned)

> **Note**: End-to-end *deployment* testing in CI (provisioning a real server per PR)
> is not implemented — it would reinstall the production server. The workflow below is
> a starting point if a dedicated test server becomes available.

```yaml
# .github/workflows/test.yml (not yet implemented)
name: Test Deployment

on:
  push:
    branches: [main]

jobs:
  test:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4

      - name: Setup Tailscale
        uses: tailscale/github-action@v2
        with:
          oauth-client-id: ${{ secrets.TS_OAUTH_CLIENT_ID }}
          oauth-secret: ${{ secrets.TS_OAUTH_SECRET }}
          tags: tag:ci

      - name: Setup OpenTofu
        uses: opentofu/setup-opentofu@v1

      - name: Deploy and Test
        env:
          OVH_ENDPOINT: ovh-eu
          OVH_APPLICATION_KEY: ${{ secrets.OVH_APP_KEY }}
          OVH_APPLICATION_SECRET: ${{ secrets.OVH_APP_SECRET }}
          OVH_CONSUMER_KEY: ${{ secrets.OVH_CONSUMER_KEY }}
        run: |
          # Adapt the example test script from above
          tofu init && tofu apply -auto-approve
```

## Metrics to Collect

For each deployment attempt, capture:

| Metric | How | Purpose |
|--------|-----|---------|
| Reinstall duration | Task timestamps | Performance baseline |
| Boot time | Serial console | Identify slow phases |
| Tailscale connect time | Polling | Network readiness |
| Cluster health time | talosctl health | Full readiness |
| Error messages | All sources | Debugging |

## Debugging Quick Reference

| Problem | First Check | Deep Dive |
|---------|-------------|-----------|
| Task failed | `ovh-server-status.sh` | Check OVH task error |
| No boot | Serial console | Rescue mode |
| No Tailscale | Public IP access | Check extension config |
| API errors | `talosctl version` | Check certificates |
| Cluster unhealthy | `talosctl health` | Check etcd, kubelet |
| CNI issues | `cilium status` | Check inline manifest |
| Storage issues | ZFS status | Check pool import |
