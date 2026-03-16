# SPDX-License-Identifier: Apache-2.0
# Copyright Maciej Sawicki

"""ZFS storage verification.

Validates ZFS pool health and persistent volume functionality.

Test plan:
  1. ZFS pool is ONLINE
  2. PersistentVolume can be created and written to on ZFS mount
"""

import json
import time

from checks import CheckContext, run_kubectl, run_talosctl
from checks.tap import TAPProducer


def run(ctx: CheckContext, tap: TAPProducer) -> None:
    """Run storage test suite."""
    if not ctx.zfs_pool_enabled:
        tap.skip("ZFS pool is ONLINE", reason="zfs_pool_enabled=false")
        tap.skip("PV write test on ZFS mount", reason="zfs_pool_enabled=false")
        return

    # 1. ZFS pool state via /proc
    #    Talos has no shell, but /proc/spl/kstat/zfs exposes pool state.
    pool_online = _check_pool_state(ctx, tap)

    # 2. PV write test
    if pool_online:
        _check_pv_write(ctx, tap)
    else:
        tap.skip("PV write test on ZFS mount", reason="pool not ONLINE")


def _check_pool_state(ctx: CheckContext, tap: TAPProducer) -> bool:
    """Check ZFS pool state via talosctl."""
    pool = ctx.zfs_pool_name

    # Try reading pool state from /proc (no shell needed)
    result = run_talosctl(
        ctx, "read", f"/proc/spl/kstat/zfs/{pool}/state",
        timeout=15,
    )

    if result.returncode == 0:
        state = result.stdout.strip().upper()
        if state == "ONLINE":
            tap.ok(f"ZFS pool '{pool}' is ONLINE")
            return True
        tap.not_ok(f"ZFS pool '{pool}' is ONLINE", state=state)
        return False

    # Fallback: try running zpool status via nsenter in a debug container
    result = run_talosctl(
        ctx, "run", "/usr/local/sbin/zpool", "status", "-p", pool,
        timeout=30,
    )
    if result.returncode == 0 and "ONLINE" in result.stdout:
        tap.ok(f"ZFS pool '{pool}' is ONLINE")
        return True

    tap.not_ok(
        f"ZFS pool '{pool}' is ONLINE",
        error=result.stderr.strip() or "pool not found",
    )
    return False


def _check_pv_write(ctx: CheckContext, tap: TAPProducer) -> None:
    """Create a hostPath PV on the ZFS mount, write a file, verify, clean up."""
    ts = int(time.time())
    pv_name = f"check-zfs-pv-{ts}"
    pvc_name = f"check-zfs-pvc-{ts}"
    pod_name = f"check-zfs-write-{ts}"
    ns = "default"
    mount_point = "/var/mnt/data"

    resources = json.dumps({
        "apiVersion": "v1",
        "kind": "List",
        "items": [
            {
                "apiVersion": "v1",
                "kind": "PersistentVolume",
                "metadata": {"name": pv_name, "labels": {"app": "cluster-check"}},
                "spec": {
                    "capacity": {"storage": "1Mi"},
                    "accessModes": ["ReadWriteOnce"],
                    "persistentVolumeReclaimPolicy": "Delete",
                    "storageClassName": "",
                    "hostPath": {"path": f"{mount_point}/check-{ts}"},
                },
            },
            {
                "apiVersion": "v1",
                "kind": "PersistentVolumeClaim",
                "metadata": {"name": pvc_name, "namespace": ns, "labels": {"app": "cluster-check"}},
                "spec": {
                    "accessModes": ["ReadWriteOnce"],
                    "resources": {"requests": {"storage": "1Mi"}},
                    "storageClassName": "",
                    "volumeName": pv_name,
                },
            },
            {
                "apiVersion": "v1",
                "kind": "Pod",
                "metadata": {"name": pod_name, "namespace": ns, "labels": {"app": "cluster-check"}},
                "spec": {
                    "containers": [{
                        "name": "writer",
                        "image": "busybox:1.37",
                        "command": ["sh", "-c", "echo ok > /data/test && cat /data/test"],
                        "volumeMounts": [{"name": "data", "mountPath": "/data"}],
                    }],
                    "volumes": [{"name": "data", "persistentVolumeClaim": {"claimName": pvc_name}}],
                    "restartPolicy": "Never",
                    "tolerations": [{
                        "key": "node-role.kubernetes.io/control-plane",
                        "operator": "Exists",
                        "effect": "NoSchedule",
                    }],
                },
            },
        ],
    })

    try:
        result = run_kubectl(ctx, "apply", "-f", "-", stdin=resources, timeout=15)
        if result.returncode != 0:
            tap.not_ok("PV write test on ZFS mount", error=f"create failed: {result.stderr.strip()}")
            return

        # Wait for pod to complete
        deadline = time.time() + 120
        while time.time() < deadline:
            result = run_kubectl(
                ctx, "get", "pod", pod_name, "-n", ns,
                "-o", "jsonpath={.status.phase}",
            )
            phase = result.stdout.strip()
            if phase == "Succeeded":
                # Check logs for the expected output
                logs = run_kubectl(ctx, "logs", pod_name, "-n", ns)
                if "ok" in logs.stdout:
                    tap.ok("PV write test on ZFS mount")
                else:
                    tap.not_ok("PV write test on ZFS mount", error="write succeeded but read failed")
                return
            if phase == "Failed":
                logs = run_kubectl(ctx, "logs", pod_name, "-n", ns)
                tap.not_ok("PV write test on ZFS mount", phase="Failed", logs=logs.stdout.strip())
                return
            time.sleep(5)

        tap.not_ok("PV write test on ZFS mount", error="pod did not complete within 120s")
    finally:
        run_kubectl(ctx, "delete", "pod", pod_name, "-n", ns, "--ignore-not-found", timeout=15)
        run_kubectl(ctx, "delete", "pvc", pvc_name, "-n", ns, "--ignore-not-found", timeout=15)
        run_kubectl(ctx, "delete", "pv", pv_name, "--ignore-not-found", timeout=15)
