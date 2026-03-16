#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# Copyright xd-ventures contributors

"""Cluster validation checks using TAP (Test Anything Protocol).

Runs post-deploy validation against a live Talos Kubernetes cluster.
Designed to be run after `tofu apply` via `make test` or `make deploy`.

Usage:
    python3 scripts/cluster_checks.py --suite smoke
    python3 scripts/cluster_checks.py --suite config
    python3 scripts/cluster_checks.py --suite storage
    python3 scripts/cluster_checks.py --suite security
    python3 scripts/cluster_checks.py --suite all

Environment variables:
    CHECK_ENDPOINT          — Talos API endpoint IP (auto-detected from tofu output)
    CHECK_NODE              — Talos node IP (defaults to CHECK_ENDPOINT)
    CHECK_TALOSCONFIG       — Path to talosconfig file (default: ./talosconfig)
    CHECK_KUBECONFIG        — Path to kubeconfig file (default: ./kubeconfig)
    CHECK_TALOS_VERSION     — Expected Talos version (e.g., v1.12.3)
    CHECK_CLUSTER_NAME      — Expected cluster name
    CHECK_CLUSTER_ENDPOINT  — Expected cluster endpoint URL
    CHECK_TAILSCALE_ENABLED — "true" if Tailscale is configured
    CHECK_FIREWALL_ENABLED  — "true" if firewall is active
    CHECK_ZFS_POOL_ENABLED  — "true" if ZFS pool is configured
    CHECK_ZFS_POOL_NAME     — ZFS pool name (default: tank)
    CHECK_ARGOCD_ENABLED    — "true" if ArgoCD is deployed
    CHECK_PUBLIC_IP         — Server public IP (for security checks)
    CHECK_TAILSCALE_IP      — Tailscale IP (for security checks)
    CHECK_API_TIMEOUT       — Seconds to wait for Talos API (default: 300)

If environment variables are not set, values are auto-detected from
`tofu output -json` when available.

Exit codes:
    0 — All tests passed (or skipped)
    1 — One or more tests failed
    2 — Invalid arguments or missing prerequisites
"""

import argparse
import os
import shutil
import sys

# Add scripts/ to path so checks package is importable
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from checks import CheckContext
from checks.tap import TAPProducer


SUITES = ["smoke", "config", "storage", "security"]


def main() -> int:
    parser = argparse.ArgumentParser(description="Cluster validation checks (TAP output)")
    parser.add_argument(
        "--suite",
        choices=SUITES + ["all"],
        default="all",
        help="Which test suite to run (default: all)",
    )
    args = parser.parse_args()

    # Build context — try env vars first, fall back to tofu output
    ctx = CheckContext.from_tofu()

    # Validate prerequisites
    if not _check_prerequisites(ctx, args.suite):
        return 2

    # Determine which suites to run
    suites = SUITES if args.suite == "all" else [args.suite]

    # Run suites
    tap = TAPProducer()
    for suite in suites:
        _run_suite(suite, ctx, tap)

    return tap.emit()


def _check_prerequisites(ctx: CheckContext, suite: str) -> bool:
    """Verify required tools and files exist."""
    errors = []

    if not shutil.which(ctx.talosctl):
        errors.append(f"talosctl not found (looked for: {ctx.talosctl})")

    if suite in ("config", "storage", "all") and not shutil.which(ctx.kubectl):
        errors.append(f"kubectl not found (looked for: {ctx.kubectl})")

    if not ctx.endpoint:
        errors.append(
            "No endpoint configured. Set CHECK_ENDPOINT or ensure tofu outputs are available."
        )

    needs_talosconfig = suite in ("smoke", "config", "storage", "all")
    if needs_talosconfig and not os.path.isfile(ctx.talosconfig):
        errors.append(
            f"talosconfig not found at {ctx.talosconfig}. "
            f"Run: tofu output -raw talosconfig > talosconfig"
        )

    needs_kubeconfig = suite in ("config", "storage", "all")
    if needs_kubeconfig and not os.path.isfile(ctx.kubeconfig):
        errors.append(
            f"kubeconfig not found at {ctx.kubeconfig}. "
            f"Run: tofu output -raw kubeconfig > kubeconfig"
        )

    if errors:
        print("Prerequisites not met:", file=sys.stderr)
        for e in errors:
            print(f"  - {e}", file=sys.stderr)
        return False
    return True


def _run_suite(suite: str, ctx: CheckContext, tap: TAPProducer) -> None:
    """Import and run a test suite."""
    from checks import smoke, config, storage, security

    dispatch = {
        "smoke": smoke.run,
        "config": config.run,
        "storage": storage.run,
        "security": security.run,
    }
    fn = dispatch.get(suite)
    if fn:
        fn(ctx, tap)


if __name__ == "__main__":
    sys.exit(main())
