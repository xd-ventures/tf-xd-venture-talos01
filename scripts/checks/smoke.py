# SPDX-License-Identifier: Apache-2.0
# Copyright xd-ventures contributors

"""Post-reinstall smoke tests.

Validates that the Talos node is alive and responsive after OVH reinstall.
These checks run before bootstrap to catch dead nodes early.

Test plan:
  1. Talos API port 50000 is reachable
  2. Talos API responds to version request
  3. Talos version matches expected
  4. Talos node reports Running stage
"""

from checks import CheckContext, run_talosctl, wait_for_port
from checks.tap import TAPProducer

TALOS_API_PORT = 50000


def run(ctx: CheckContext, tap: TAPProducer) -> None:
    """Run smoke test suite."""
    # 1. Port reachability
    if not ctx.endpoint:
        tap.not_ok(
            "Talos API port 50000 is reachable",
            error="No endpoint configured",
            hint="Set CHECK_ENDPOINT or ensure talosconfig exists",
        )
        _skip_rest(tap, "no endpoint")
        return

    reachable = wait_for_port(ctx.endpoint, TALOS_API_PORT, ctx.api_timeout)
    if reachable:
        tap.ok("Talos API port 50000 is reachable")
    else:
        tap.not_ok(
            "Talos API port 50000 is reachable",
            error=f"Connection to {ctx.endpoint}:{TALOS_API_PORT} timed out after {ctx.api_timeout}s",
            hint="Check if the server completed boot. Use iKVM for console output.",
        )
        _skip_rest(tap, "port unreachable")
        return

    # 2. Talos API responds
    result = run_talosctl(ctx, "version", "--short")
    if result.returncode == 0:
        tap.ok("Talos API responds to version request")
    else:
        tap.not_ok(
            "Talos API responds to version request",
            error=result.stderr.strip(),
        )
        _skip_rest(tap, "API not responding", skip_count=2)
        return

    # 3. Version matches
    version_output = result.stdout.strip()
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

    # 4. Machine stage is Running
    result = run_talosctl(
        ctx, "get", "machinestatus",
        "-o", "jsonpath={.spec.stage}",
    )
    stage = result.stdout.strip()
    if stage == "running":
        tap.ok("Talos node reports Running stage")
    else:
        tap.not_ok(
            "Talos node reports Running stage",
            expected="running",
            actual=stage or result.stderr.strip(),
        )


def _skip_rest(tap: TAPProducer, reason: str, skip_count: int = 3) -> None:
    """Skip remaining tests when a prerequisite fails."""
    skips = [
        "Talos API responds to version request",
        "Talos version matches expected",
        "Talos node reports Running stage",
    ]
    for desc in skips[-skip_count:]:
        tap.skip(desc, reason=f"prerequisite failed: {reason}")
