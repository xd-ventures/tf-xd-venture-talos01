# SPDX-License-Identifier: Apache-2.0
# Copyright Maciej Sawicki

"""Storage & backup verification.

Validates ZFS pool health, the zfs-localpv PVC path (#320), and etcd
backup recency (talos-backup CronJobs, #316 / ADR-0018).

Test plan:
  1. ZFS pool is ONLINE
  2. PVC create + write via the zfs-localpv StorageClass (dynamic provisioning)
  3. VolumeSnapshot of that PVC reaches readyToUse (ZFS-native snapshot)
  4. etcd snapshot CronJob succeeded recently (< 8h)
  5. backup decrypt-and-verify CronJob succeeded recently (< 26h)
"""

import datetime
import json
import time

from checks import CheckContext, run_kubectl, run_talosctl
from checks.tap import TAPProducer


def run(ctx: CheckContext, tap: TAPProducer) -> None:
    """Run storage test suite."""
    if not ctx.zfs_pool_enabled:
        tap.skip("ZFS pool is ONLINE", reason="zfs_pool_enabled=false")
        tap.skip("PVC write test (zfs-localpv)", reason="zfs_pool_enabled=false")
        tap.skip("PVC snapshot round-trip (zfs-localpv)", reason="zfs_pool_enabled=false")
    else:
        # 1. ZFS pool state via /proc
        #    Talos has no shell, but /proc/spl/kstat/zfs exposes pool state.
        pool_online = _check_pool_state(ctx, tap)

        # 2+3. PVC write + snapshot round-trip through the zfs-localpv
        #      StorageClass (#320) — exercises the CSI provisioner end to end,
        #      not just the pool.
        if pool_online:
            _check_pvc_roundtrip(ctx, tap)
        else:
            tap.skip("PVC write test (zfs-localpv)", reason="pool not ONLINE")
            tap.skip("PVC snapshot round-trip (zfs-localpv)", reason="pool not ONLINE")

    # 3+4. etcd backup recency (ADR-0018: a silently dead backup CronJob or
    # an unrestorable snapshot must surface within a day, not at a drill)
    if not ctx.talos_backup_enabled:
        tap.skip("etcd snapshot CronJob recent", reason="talos_backup_enabled=false")
        tap.skip("backup verify CronJob recent", reason="talos_backup_enabled=false")
    else:
        _check_cronjob_recency(
            ctx, tap, "talos-backup",
            max_age_hours=8, description="etcd snapshot CronJob recent",
        )
        _check_cronjob_recency(
            ctx, tap, "talos-backup-verify",
            max_age_hours=26, description="backup verify CronJob recent",
        )


def _check_cronjob_recency(
    ctx: CheckContext,
    tap: TAPProducer,
    name: str,
    max_age_hours: int,
    description: str,
) -> None:
    """Assert a CronJob in the talos-backup namespace succeeded recently.

    Uses status.lastSuccessfulTime — the backup Job completes only after the
    S3 upload (and the verify Job only after a successful decrypt), so this
    is an end-to-end freshness signal that needs no S3 credentials in CI.
    """
    result = run_kubectl(
        ctx, "get", "cronjob", "-n", "talos-backup", name, "-o", "json",
        timeout=30,
    )
    if result.returncode != 0:
        tap.not_ok(description, error=f"kubectl get cronjob {name} failed: {result.stderr.strip()}")
        return

    try:
        status = json.loads(result.stdout).get("status", {})
    except json.JSONDecodeError:
        tap.not_ok(description, error=f"unparseable cronjob JSON for {name}")
        return

    last_success = status.get("lastSuccessfulTime")
    if not last_success:
        tap.not_ok(description, error=f"{name} has no successful run yet")
        return

    ts = datetime.datetime.fromisoformat(last_success.replace("Z", "+00:00"))
    age = datetime.datetime.now(datetime.timezone.utc) - ts
    if age > datetime.timedelta(hours=max_age_hours):
        tap.not_ok(
            description,
            error=f"{name} last succeeded {age.total_seconds() / 3600:.1f}h ago (max {max_age_hours}h)",
        )
    else:
        tap.ok(description)


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

    # No fallback: 'talosctl run' does not exist (Talos has no shell), so the
    # old fallback always failed and masked the real /proc read error (#245).
    # For manual debugging use the debug-pod pattern in the Operations Runbook.
    tap.not_ok(
        f"ZFS pool '{pool}' is ONLINE",
        error=result.stderr.strip()
        or f"could not read /proc/spl/kstat/zfs/{pool}/state",
        hint="pool missing or ZFS extension not loaded; see OPERATIONS_RUNBOOK.md",
    )
    return False


def _check_pvc_roundtrip(ctx: CheckContext, tap: TAPProducer) -> None:
    """PVC create/write + VolumeSnapshot round-trip via zfs-localpv (#320).

    Exercises dynamic provisioning through the openebs-zfspv StorageClass
    (WaitForFirstConsumer: the PVC binds when the writer pod schedules) and a
    ZFS-native CSI snapshot. Replaces the old hostPath PV test, which bypassed
    the provisioner entirely.
    """
    ts = int(time.time())
    pvc_name = f"check-zfspv-{ts}"
    pod_name = f"check-zfspv-write-{ts}"
    snap_name = f"check-zfspv-snap-{ts}"
    ns = "default"
    write_desc = "PVC write test (zfs-localpv)"
    snap_desc = "PVC snapshot round-trip (zfs-localpv)"

    resources = json.dumps({
        "apiVersion": "v1",
        "kind": "List",
        "items": [
            {
                "apiVersion": "v1",
                "kind": "PersistentVolumeClaim",
                "metadata": {"name": pvc_name, "namespace": ns, "labels": {"app": "cluster-check"}},
                "spec": {
                    "accessModes": ["ReadWriteOnce"],
                    "resources": {"requests": {"storage": "16Mi"}},
                    "storageClassName": "openebs-zfspv",
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

    snapshot = json.dumps({
        "apiVersion": "snapshot.storage.k8s.io/v1",
        "kind": "VolumeSnapshot",
        "metadata": {"name": snap_name, "namespace": ns, "labels": {"app": "cluster-check"}},
        "spec": {
            "volumeSnapshotClassName": "openebs-zfspv",
            "source": {"persistentVolumeClaimName": pvc_name},
        },
    })

    try:
        result = run_kubectl(ctx, "apply", "-f", "-", stdin=resources, timeout=15)
        if result.returncode != 0:
            tap.not_ok(write_desc, error=f"create failed: {result.stderr.strip()}")
            tap.skip(snap_desc, reason="PVC/pod create failed")
            return

        # Wait for the writer pod (provisioning happens on schedule: WFFC)
        deadline = time.time() + 120
        wrote = False
        while time.time() < deadline:
            result = run_kubectl(
                ctx, "get", "pod", pod_name, "-n", ns,
                "-o", "jsonpath={.status.phase}",
            )
            phase = result.stdout.strip()
            if phase == "Succeeded":
                logs = run_kubectl(ctx, "logs", pod_name, "-n", ns)
                if "ok" in logs.stdout:
                    tap.ok(write_desc)
                    wrote = True
                else:
                    tap.not_ok(write_desc, error="write succeeded but read failed")
                break
            if phase == "Failed":
                logs = run_kubectl(ctx, "logs", pod_name, "-n", ns)
                tap.not_ok(write_desc, phase="Failed", logs=logs.stdout.strip())
                break
            time.sleep(5)
        else:
            # PVC stuck Pending usually means the provisioner/topology is broken.
            pvc = run_kubectl(
                ctx, "get", "pvc", pvc_name, "-n", ns,
                "-o", "jsonpath={.status.phase}",
            )
            tap.not_ok(
                write_desc,
                error="pod did not complete within 120s",
                pvc_phase=pvc.stdout.strip() or "unknown",
            )

        if not wrote:
            tap.skip(snap_desc, reason="write test failed")
            return

        # Snapshot the written volume; readyToUse proves the CSI snapshot path
        # (snapshot-controller + csi-snapshotter + zfs snapshot) end to end.
        result = run_kubectl(ctx, "apply", "-f", "-", stdin=snapshot, timeout=15)
        if result.returncode != 0:
            tap.not_ok(snap_desc, error=f"snapshot create failed: {result.stderr.strip()}")
            return

        deadline = time.time() + 90
        while time.time() < deadline:
            result = run_kubectl(
                ctx, "get", "volumesnapshot", snap_name, "-n", ns,
                "-o", "jsonpath={.status.readyToUse}",
            )
            if result.stdout.strip() == "true":
                tap.ok(snap_desc)
                return
            time.sleep(5)

        tap.not_ok(snap_desc, error="snapshot not readyToUse within 90s")
    finally:
        run_kubectl(
            ctx, "delete", "volumesnapshot", snap_name, "-n", ns,
            "--ignore-not-found", timeout=30,
        )
        run_kubectl(ctx, "delete", "pod", pod_name, "-n", ns, "--ignore-not-found", timeout=15)
        run_kubectl(ctx, "delete", "pvc", pvc_name, "-n", ns, "--ignore-not-found", timeout=30)
