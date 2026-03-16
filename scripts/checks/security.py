# SPDX-License-Identifier: Apache-2.0
# Copyright xd-ventures contributors

"""Firewall and security verification.

Validates that the Talos firewall rules are effective: public IP ports
are blocked while Tailscale IP ports remain accessible.

Test plan:
  1-3. Public IP critical ports are NOT reachable (50000, 6443, 10250)
  4-5. Tailscale IP critical ports ARE reachable (50000, 6443)
  6.   Broad port scan — no unexpected open ports on public IP
"""

import socket

from checks import CheckContext, check_port_closed
from checks.tap import TAPProducer

# Ports that MUST be blocked on public IP when firewall is enabled
BLOCKED_PORTS = {
    50000: "Talos API",
    6443: "Kubernetes API",
    10250: "Kubelet",
    2379: "etcd client",
    2380: "etcd peer",
}

# Ports that MUST be open on Tailscale IP
TAILSCALE_OPEN_PORTS = {
    50000: "Talos API",
    6443: "Kubernetes API",
}

# Broader scan: service ports that should not be exposed publicly
SCAN_PORTS = [
    22, 80, 443, 2379, 2380, 4240, 4244, 4245,
    6443, 8080, 8443, 8472, 9090, 10250, 10255, 50000, 50001,
]


def run(ctx: CheckContext, tap: TAPProducer) -> None:
    """Run security test suite."""
    # Public IP port checks (only meaningful when firewall is enabled)
    if not ctx.firewall_enabled:
        for port, service in BLOCKED_PORTS.items():
            tap.skip(
                f"Public IP port {port} ({service}) is blocked",
                reason="firewall_enabled=false",
            )
    elif not ctx.public_ip:
        for port, service in BLOCKED_PORTS.items():
            tap.skip(
                f"Public IP port {port} ({service}) is blocked",
                reason="CHECK_PUBLIC_IP not set",
            )
    else:
        for port, service in BLOCKED_PORTS.items():
            _check_port_blocked(ctx, tap, ctx.public_ip, port, service)

    # Tailscale IP port checks
    if not ctx.tailscale_enabled:
        for port, service in TAILSCALE_OPEN_PORTS.items():
            tap.skip(
                f"Tailscale IP port {port} ({service}) is reachable",
                reason="tailscale_enabled=false",
            )
    elif not ctx.tailscale_ip and not ctx.endpoint:
        for port, service in TAILSCALE_OPEN_PORTS.items():
            tap.skip(
                f"Tailscale IP port {port} ({service}) is reachable",
                reason="no Tailscale IP available",
            )
    else:
        ts_ip = ctx.tailscale_ip or ctx.endpoint
        for port, service in TAILSCALE_OPEN_PORTS.items():
            _check_port_open(ctx, tap, ts_ip, port, service)

    # Broad port scan on public IP
    if ctx.firewall_enabled and ctx.public_ip:
        _broad_port_scan(ctx, tap)
    else:
        reason = "firewall_enabled=false" if not ctx.firewall_enabled else "CHECK_PUBLIC_IP not set"
        tap.skip("No unexpected open ports on public IP", reason=reason)


def _check_port_blocked(ctx: CheckContext, tap: TAPProducer, host: str, port: int, service: str) -> None:
    """Verify a port is NOT reachable (3 attempts to avoid false positives)."""
    blocked_count = 0
    for _ in range(3):
        if check_port_closed(host, port, timeout=3):
            blocked_count += 1

    if blocked_count == 3:
        tap.ok(f"Public IP port {port} ({service}) is blocked")
    else:
        tap.not_ok(
            f"Public IP port {port} ({service}) is blocked",
            error=f"port responded {3 - blocked_count}/3 attempts",
            host=host,
        )


def _check_port_open(ctx: CheckContext, tap: TAPProducer, host: str, port: int, service: str) -> None:
    """Verify a port IS reachable via Tailscale."""
    try:
        with socket.create_connection((host, port), timeout=10):
            tap.ok(f"Tailscale IP port {port} ({service}) is reachable")
    except (OSError, ConnectionRefusedError) as e:
        tap.not_ok(
            f"Tailscale IP port {port} ({service}) is reachable",
            error=str(e),
            host=host,
        )


def _broad_port_scan(ctx: CheckContext, tap: TAPProducer) -> None:
    """Scan common service ports on public IP — none should be open."""
    open_ports = []
    for port in SCAN_PORTS:
        if not check_port_closed(ctx.public_ip, port, timeout=3):
            open_ports.append(port)

    if not open_ports:
        tap.ok("No unexpected open ports on public IP")
    else:
        tap.not_ok(
            "No unexpected open ports on public IP",
            open_ports=", ".join(str(p) for p in open_ports),
            host=ctx.public_ip,
        )
