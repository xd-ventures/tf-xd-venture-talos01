"""Post-bootstrap config validation.

Validates that the cluster state matches the intended configuration
after bootstrap completes. Catches config drive corruption, missing
extensions, and failed inline manifests.

Test plan:
  1. Talos API responds after bootstrap
  2. Talos version matches expected
  3. Extension loaded (one test per expected extension)
  4. Node is Ready in Kubernetes
  5. Cluster endpoint matches expected
  6. Cilium install Job completed
  7. Cilium DaemonSet is ready
  8. ZFS pool Job completed (conditional)
  9. CoreDNS pods running
  10. Pod lifecycle works (create, run, delete)
  11. ArgoCD is healthy (conditional)
"""

import json
import time

from checks import CheckContext, run_kubectl, run_talosctl
from checks.tap import TAPProducer


def run(ctx: CheckContext, tap: TAPProducer) -> None:
    """Run config validation suite."""
    # 1. Talos API responds
    result = run_talosctl(ctx, "version", "--short")
    if result.returncode != 0:
        tap.not_ok(
            "Talos API responds after bootstrap",
            error=result.stderr.strip(),
        )
        return
    tap.ok("Talos API responds after bootstrap")
    version_output = result.stdout.strip()

    # 2. Version matches
    if ctx.talos_version and ctx.talos_version in version_output:
        tap.ok(f"Talos version matches {ctx.talos_version}")
    elif not ctx.talos_version:
        tap.skip("Talos version matches expected", reason="CHECK_TALOS_VERSION not set")
    else:
        tap.not_ok(
            f"Talos version matches {ctx.talos_version}",
            expected=ctx.talos_version,
            actual=version_output,
        )

    # 3. Extensions loaded
    _check_extensions(ctx, tap)

    # 4. Node is Ready
    node_ready = _check_node_ready(ctx, tap)

    # 5. Cluster endpoint
    if ctx.cluster_endpoint:
        result = run_talosctl(
            ctx, "get", "config",
            "-o", "jsonpath={.cluster.controlPlane.endpoint}",
            timeout=15,
        )
        actual_endpoint = result.stdout.strip()
        if ctx.cluster_endpoint in actual_endpoint or actual_endpoint in ctx.cluster_endpoint:
            tap.ok(f"Cluster endpoint matches {ctx.cluster_endpoint}")
        else:
            tap.not_ok(
                f"Cluster endpoint matches {ctx.cluster_endpoint}",
                expected=ctx.cluster_endpoint,
                actual=actual_endpoint or result.stderr.strip(),
            )
    else:
        tap.skip("Cluster endpoint matches expected", reason="CHECK_CLUSTER_ENDPOINT not set")

    if not node_ready:
        tap.skip("Cilium install Job completed", reason="node not ready")
        tap.skip("Cilium DaemonSet is ready", reason="node not ready")
        if ctx.zfs_pool_enabled:
            tap.skip("ZFS pool Job completed", reason="node not ready")
        tap.skip("CoreDNS pods running", reason="node not ready")
        tap.skip("Pod lifecycle works", reason="node not ready")
        if ctx.argocd_enabled:
            tap.skip("ArgoCD server is running", reason="node not ready")
        return

    # 6. Cilium install Job
    _check_job(ctx, tap, "cilium-install", "kube-system", "Cilium install Job completed")

    # 7. Cilium DaemonSet
    result = run_kubectl(
        ctx, "get", "ds", "cilium", "-n", "kube-system",
        "-o", "jsonpath={.status.numberReady}",
    )
    ready = result.stdout.strip()
    if ready and int(ready) >= 1:
        tap.ok("Cilium DaemonSet is ready")
    else:
        tap.not_ok(
            "Cilium DaemonSet is ready",
            ready_count=ready or "0",
            error=result.stderr.strip() if result.returncode != 0 else "",
        )

    # 8. ZFS pool Job (conditional)
    if ctx.zfs_pool_enabled:
        _check_job(ctx, tap, "zfs-pool-setup", "kube-system", "ZFS pool Job completed")
    # 9. CoreDNS
    result = run_kubectl(
        ctx, "get", "pods", "-n", "kube-system",
        "-l", "k8s-app=kube-dns",
        "-o", "jsonpath={.items[*].status.phase}",
    )
    phases = result.stdout.strip().split()
    if phases and all(p == "Running" for p in phases):
        tap.ok("CoreDNS pods running")
    else:
        tap.not_ok(
            "CoreDNS pods running",
            phases=" ".join(phases) if phases else "no pods found",
        )

    # 10. Pod lifecycle
    _check_pod_lifecycle(ctx, tap)

    # 11. ArgoCD (conditional)
    if ctx.argocd_enabled:
        _check_argocd(ctx, tap)


def _check_extensions(ctx: CheckContext, tap: TAPProducer) -> None:
    """Verify expected Talos extensions are loaded."""
    # talosctl outputs concatenated JSON objects (not JSONL, not an array)
    # Use a simple regex to extract extension names
    result = run_talosctl(ctx, "get", "extensions", "-o", "json", timeout=15)
    if result.returncode != 0:
        tap.not_ok("Extensions query succeeded", error=result.stderr.strip())
        return

    loaded = set()
    # Parse concatenated JSON objects using decoder
    output = result.stdout
    decoder = json.JSONDecoder()
    pos = 0
    while pos < len(output):
        # Skip whitespace and warning lines
        while pos < len(output) and output[pos] != "{":
            pos += 1
        if pos >= len(output):
            break
        try:
            obj, end = decoder.raw_decode(output, pos)
            name = obj.get("spec", {}).get("metadata", {}).get("name", "")
            if name:
                loaded.add(name)
            pos = end
        except json.JSONDecodeError:
            pos += 1

    expected = ["zfs"]
    if ctx.tailscale_enabled:
        expected.append("tailscale")

    for ext in expected:
        matches = [n for n in loaded if ext in n.lower()]
        if matches:
            tap.ok(f"Extension '{ext}' is loaded")
        else:
            tap.not_ok(
                f"Extension '{ext}' is loaded",
                loaded=", ".join(sorted(loaded)) or "none",
            )


def _check_node_ready(ctx: CheckContext, tap: TAPProducer) -> bool:
    """Check if the Kubernetes node is Ready. Returns True if ready."""
    result = run_kubectl(
        ctx, "get", "nodes",
        "-o", "jsonpath={.items[0].status.conditions[?(@.type==\"Ready\")].status}",
        timeout=15,
    )
    status = result.stdout.strip()
    if status == "True":
        tap.ok("Node is Ready in Kubernetes")
        return True
    tap.not_ok(
        "Node is Ready in Kubernetes",
        status=status or "unknown",
        error=result.stderr.strip() if result.returncode != 0 else "",
    )
    return False


def _check_job(ctx: CheckContext, tap: TAPProducer, job_name: str, namespace: str, description: str) -> None:
    """Check if a Kubernetes Job completed successfully.

    Jobs have ttlSecondsAfterFinished=600, so a NotFound result means
    the Job already completed and was cleaned up — that's a pass.
    """
    result = run_kubectl(
        ctx, "get", "job", job_name, "-n", namespace,
        "-o", "jsonpath={.status.succeeded}",
    )
    succeeded = result.stdout.strip()
    try:
        succeeded_count = int(succeeded) if succeeded else 0
    except ValueError:
        succeeded_count = 0

    if succeeded_count > 0:
        tap.ok(description)
    elif result.returncode != 0 and "NotFound" in result.stderr:
        tap.ok(f"{description} (cleaned up by TTL)")
    else:
        tap.not_ok(
            description,
            succeeded=succeeded or "0",
            error=result.stderr.strip() if result.returncode != 0 else "",
        )


def _check_pod_lifecycle(ctx: CheckContext, tap: TAPProducer) -> None:
    """Create a dummy pod, verify it runs, clean up."""
    pod_name = f"cluster-check-{int(time.time())}"
    ns = "default"
    manifest = json.dumps({
        "apiVersion": "v1",
        "kind": "Pod",
        "metadata": {
            "name": pod_name,
            "namespace": ns,
            "labels": {"app": "cluster-check"},
        },
        "spec": {
            "containers": [{
                "name": "test",
                "image": "busybox:1.37",
                "command": ["sleep", "30"],
            }],
            "restartPolicy": "Never",
            "tolerations": [{
                "key": "node-role.kubernetes.io/control-plane",
                "operator": "Exists",
                "effect": "NoSchedule",
            }],
        },
    })

    try:
        # Create pod
        result = run_kubectl(ctx, "apply", "-f", "-", stdin=manifest, timeout=15)
        if result.returncode != 0:
            tap.not_ok("Pod lifecycle works", error=f"create failed: {result.stderr.strip()}")
            return

        # Wait for Running (up to 120s for image pull)
        deadline = time.time() + 120
        phase = ""
        while time.time() < deadline:
            result = run_kubectl(
                ctx, "get", "pod", pod_name, "-n", ns,
                "-o", "jsonpath={.status.phase}",
            )
            phase = result.stdout.strip()
            if phase == "Running":
                tap.ok("Pod lifecycle works (create, run, delete)")
                return
            if phase in ("Failed", "Unknown"):
                tap.not_ok("Pod lifecycle works", phase=phase)
                return
            time.sleep(5)

        tap.not_ok(
            "Pod lifecycle works",
            error=f"pod did not reach Running within 120s",
            last_phase=phase,
        )
    finally:
        run_kubectl(ctx, "delete", "pod", pod_name, "-n", ns, "--ignore-not-found", timeout=30)


def _check_argocd(ctx: CheckContext, tap: TAPProducer) -> None:
    """Verify ArgoCD server pod is running."""
    result = run_kubectl(
        ctx, "get", "pods", "-n", "argocd",
        "-l", "app.kubernetes.io/name=argocd-server",
        "-o", "jsonpath={.items[0].status.phase}",
    )
    phase = result.stdout.strip()
    if phase == "Running":
        tap.ok("ArgoCD server is running")
    else:
        tap.not_ok(
            "ArgoCD server is running",
            phase=phase or "not found",
            error=result.stderr.strip() if result.returncode != 0 else "",
        )
