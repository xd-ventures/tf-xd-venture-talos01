# SPDX-License-Identifier: Apache-2.0
# Copyright Maciej Sawicki

"""Cluster validation checks — shared context and utilities."""

import json
import os
import re
import shutil
import socket
import subprocess
import time
from collections.abc import Callable
from dataclasses import dataclass
from urllib.parse import urlparse

# Validation patterns
_HOSTNAME_RE = re.compile(r"^[a-zA-Z0-9._:-]+$")
_VERSION_RE = re.compile(r"^v?\d+\.\d+\.\d+")
_POOL_NAME_RE = re.compile(r"^[a-zA-Z0-9_-]+$")
_PATH_RE = re.compile(r"^[a-zA-Z0-9_./ -]+$")


def _validate_host(value: str, name: str) -> str:
    """Validate a hostname or IP address."""
    if not value:
        return value
    if not _HOSTNAME_RE.match(value):
        raise ValueError(f"Invalid {name}: {value!r} — must be a hostname or IP")
    return value


def _validate_path(value: str, name: str) -> str:
    """Validate a filesystem path (no shell metacharacters)."""
    if not value:
        return value
    if not _PATH_RE.match(value):
        raise ValueError(f"Invalid {name}: {value!r} — contains disallowed characters")
    return value


def _validate_version(value: str, name: str) -> str:
    """Validate a version string."""
    if not value:
        return value
    if not _VERSION_RE.match(value):
        raise ValueError(f"Invalid {name}: {value!r} — expected semver format")
    return value


def _validate_pool_name(value: str, name: str) -> str:
    """Validate a ZFS pool name (alphanumeric, underscore, dash)."""
    if not value:
        return value
    if not _POOL_NAME_RE.match(value):
        raise ValueError(f"Invalid {name}: {value!r} — must be alphanumeric")
    return value


def _resolve_binary(name: str) -> str:
    """Resolve a binary name to its absolute path via which."""
    path = shutil.which(name)
    if path:
        return os.path.realpath(path)
    return name


@dataclass
class CheckContext:
    """Configuration for cluster validation checks.

    All values are populated from environment variables (CHECK_*) when run
    via Makefile, or from tofu output when run interactively. All inputs
    are validated at construction time.
    """

    # Connection — resolved to absolute paths / validated hostnames
    talosctl: str = ""
    kubectl: str = ""
    talosconfig: str = ""
    kubeconfig: str = ""
    endpoint: str = ""
    node: str = ""

    # Expected state
    talos_version: str = ""
    cluster_name: str = ""
    cluster_endpoint: str = ""

    # Feature flags
    tailscale_enabled: bool = False
    firewall_enabled: bool = False
    zfs_pool_enabled: bool = False
    argocd_enabled: bool = False
    talos_backup_enabled: bool = False
    zfs_pool_name: str = "tank"

    # Network
    public_ip: str = ""
    tailscale_ip: str = ""

    # Timeouts
    api_timeout: int = 300
    boot_timeout: int = 600

    @classmethod
    def from_env(cls) -> "CheckContext":
        """Build context from CHECK_* environment variables.

        All string inputs are validated against allowlists to prevent
        injection via crafted environment variables.
        """
        ctx = cls(
            talosctl=_resolve_binary("talosctl"),
            kubectl=_resolve_binary("kubectl"),
            talosconfig=_validate_path(
                os.environ.get("CHECK_TALOSCONFIG", "talosconfig"), "CHECK_TALOSCONFIG"
            ),
            kubeconfig=_validate_path(
                os.environ.get("CHECK_KUBECONFIG", "kubeconfig"), "CHECK_KUBECONFIG"
            ),
            endpoint=_validate_host(
                os.environ.get("CHECK_ENDPOINT", ""), "CHECK_ENDPOINT"
            ),
            node=_validate_host(
                os.environ.get("CHECK_NODE", ""), "CHECK_NODE"
            ),
            talos_version=_validate_version(
                os.environ.get("CHECK_TALOS_VERSION", ""), "CHECK_TALOS_VERSION"
            ),
            cluster_name=os.environ.get("CHECK_CLUSTER_NAME", ""),
            cluster_endpoint=os.environ.get("CHECK_CLUSTER_ENDPOINT", ""),
            tailscale_enabled=os.environ.get("CHECK_TAILSCALE_ENABLED", "").lower()
            == "true",
            firewall_enabled=os.environ.get("CHECK_FIREWALL_ENABLED", "").lower()
            == "true",
            zfs_pool_enabled=os.environ.get("CHECK_ZFS_POOL_ENABLED", "").lower()
            == "true",
            argocd_enabled=os.environ.get("CHECK_ARGOCD_ENABLED", "").lower()
            == "true",
            talos_backup_enabled=os.environ.get("CHECK_TALOS_BACKUP_ENABLED", "").lower()
            == "true",
            zfs_pool_name=_validate_pool_name(
                os.environ.get("CHECK_ZFS_POOL_NAME", "tank"), "CHECK_ZFS_POOL_NAME"
            ),
            public_ip=_validate_host(
                os.environ.get("CHECK_PUBLIC_IP", ""), "CHECK_PUBLIC_IP"
            ),
            tailscale_ip=_validate_host(
                os.environ.get("CHECK_TAILSCALE_IP", ""), "CHECK_TAILSCALE_IP"
            ),
            api_timeout=int(os.environ.get("CHECK_API_TIMEOUT", "300")),
            boot_timeout=int(os.environ.get("CHECK_BOOT_TIMEOUT", "600")),
        )
        return ctx

    @classmethod
    def from_tofu(cls) -> "CheckContext":
        """Build context by querying tofu output values."""
        ctx = cls.from_env()

        outputs = _tofu_outputs()
        if not outputs:
            return ctx

        if not ctx.talos_version:
            installer = _get(outputs, "talos_installer_image", "")
            if ":" in installer:
                ctx.talos_version = _validate_version(
                    installer.rsplit(":", 1)[-1], "talos_installer_image"
                )
        ctx.public_ip = ctx.public_ip or _validate_host(
            _get(outputs, "server_ip", ""), "server_ip"
        )
        ctx.firewall_enabled = ctx.firewall_enabled or _get(
            outputs, "firewall_enabled", False
        )
        ctx.tailscale_enabled = ctx.tailscale_enabled or _get(
            outputs, "tailscale_enabled", False
        )
        ctx.argocd_enabled = ctx.argocd_enabled or _get(
            outputs, "argocd_enabled", False
        )
        ctx.cluster_endpoint = ctx.cluster_endpoint or _get(
            outputs, "cluster_endpoint_actual", ""
        )

        tailscale_ip = _validate_host(
            _get(outputs, "tailscale_device_ip", ""), "tailscale_device_ip"
        )
        if tailscale_ip:
            ctx.tailscale_ip = tailscale_ip

        backup_info = _get(outputs, "talos_backup_info", None)
        if isinstance(backup_info, dict):
            ctx.talos_backup_enabled = ctx.talos_backup_enabled or bool(
                backup_info.get("enabled")
            )

        zfs_info = _get(outputs, "zfs_pool_info", None)
        if isinstance(zfs_info, dict):
            ctx.zfs_pool_enabled = zfs_info.get("status", "").lower().startswith("enabled")
            ctx.zfs_pool_name = _validate_pool_name(
                zfs_info.get("pool_name", ctx.zfs_pool_name), "zfs_pool_name"
            )

        if not ctx.endpoint:
            if ctx.tailscale_enabled and ctx.tailscale_ip:
                ctx.endpoint = ctx.tailscale_ip
            elif ctx.public_ip:
                ctx.endpoint = ctx.public_ip
        ctx.node = ctx.node or ctx.endpoint

        return ctx


# --- Output redaction --------------------------------------------------
# CI publishes TAP output in public Actions run logs and Job Summaries
# (the repository is public), so live infrastructure identifiers —
# endpoints, IPs, the tailnet hostname, cluster name — must never appear
# in it. Redaction is ON by default; set CHECK_REDACT=false for local
# debugging where the actual values are needed.

_IPV4_RE = re.compile(r"\b(?:\d{1,3}\.){3}\d{1,3}\b")
# ::-compressed forms must precede the full form in the alternation, or the
# full-form branch consumes the head of "a:b:c::d" and leaks "::d". All
# repetitions are bounded (IPv6 has at most 8 groups) to keep matching linear
# on adversarial input. May also match MAC-like hex:colon strings and
# HH:MM:SS timestamps — over-redacting those is acceptable.
_IPV6_RE = re.compile(
    r"(?:[0-9A-Fa-f]{1,4}:){1,7}:(?:[0-9A-Fa-f]{1,4}(?::[0-9A-Fa-f]{1,4}){0,6})?"
    r"|(?<![\w:])::(?:[0-9A-Fa-f]{1,4}(?::[0-9A-Fa-f]{1,4}){0,7})"
    r"|\b(?:[0-9A-Fa-f]{1,4}:){2,7}[0-9A-Fa-f]{1,4}\b"
)
_TSNET_RE = re.compile(r"\b[\w][\w.-]*\.ts\.net\b", re.IGNORECASE)


def redact_disabled() -> bool:
    """True when the operator explicitly disabled redaction (local debugging)."""
    return os.environ.get("CHECK_REDACT", "true").strip().lower() in ("false", "0", "no")


def redact_patterns(text: str) -> str:
    """Pattern-only scrubbing (IPv4/IPv6/*.ts.net) — usable even when no
    CheckContext exists, e.g. for fatal errors during context construction."""
    text = _TSNET_RE.sub("[ts-hostname]", text)
    text = _IPV4_RE.sub("[ipv4]", text)
    text = _IPV6_RE.sub("[ipv6]", text)
    return text


def build_redactor(ctx: "CheckContext") -> Callable[[str], str]:
    """Build a callable that scrubs live identifiers from output text.

    Replaces known context values with stable placeholders, then applies
    pattern-based scrubbing (IPv4/IPv6/*.ts.net) to catch identifiers
    embedded in subprocess stderr (e.g. gRPC dial errors).
    """
    if redact_disabled():
        return lambda text: text

    pairs: list[tuple[str, str]] = []
    seen: set[str] = set()

    def add(value: str, placeholder: str) -> None:
        # Skip short values — replacing them would mangle unrelated text
        if value and len(value) >= 4 and value not in seen:
            seen.add(value)
            pairs.append((value, placeholder))

    add(ctx.cluster_endpoint, "[cluster-endpoint]")
    if ctx.cluster_endpoint:
        add(urlparse(ctx.cluster_endpoint).hostname or "", "[cluster-host]")
    add(ctx.endpoint, "[endpoint]")
    add(ctx.node, "[node]")
    add(ctx.public_ip, "[public-ip]")
    add(ctx.tailscale_ip, "[tailscale-ip]")
    add(ctx.cluster_name, "[cluster-name]")
    add(ctx.talos_version, "[talos-version]")
    add(ctx.talos_version.lstrip("vV"), "[talos-version]")

    if not pairs:
        return redact_patterns

    # Single-pass substitution via one alternation: replaced text is never
    # re-scanned, so a value that happens to be a substring of another value
    # or of a placeholder cannot garble the output. Longest-first ordering
    # makes the alternation prefer the most specific value at each position.
    pairs.sort(key=lambda p: len(p[0]), reverse=True)
    placeholder_by_value = dict(pairs)
    values_re = re.compile("|".join(re.escape(value) for value, _ in pairs))

    def redact(text: str) -> str:
        text = values_re.sub(lambda m: placeholder_by_value[m.group(0)], text)
        return redact_patterns(text)

    return redact


def _tofu_outputs() -> dict:
    """Query all tofu outputs as JSON.

    Outputs live in the infra/ consumer root after the module extraction, so
    run tofu there (via -chdir) rather than the invocation cwd. Harmless in CI
    where infra/ is not initialized — the non-zero return is caught below and
    the checks fall back to CHECK_* env inputs.
    """
    try:
        result = _safe_run(
            [_resolve_binary("tofu"), "-chdir=infra", "output", "-json"], timeout=30
        )
        if result.returncode != 0:
            return {}
        raw = json.loads(result.stdout)
        return {k: v.get("value") for k, v in raw.items()}
    except json.JSONDecodeError:
        return {}


def _get(outputs: dict, key: str, default):
    """Get a value from outputs dict with a default."""
    val = outputs.get(key)
    return val if val is not None else default


def wait_for_port(host: str, port: int, timeout: int) -> bool:
    """Poll TCP port with backoff. Returns True if reachable within timeout."""
    deadline = time.time() + timeout
    delay = 2
    while time.time() < deadline:
        try:
            with socket.create_connection((host, port), timeout=5):
                return True
        except (OSError, ConnectionRefusedError):
            time.sleep(min(delay, max(0, deadline - time.time())))
            delay = min(delay * 1.5, 30)
    return False


def check_port_closed(host: str, port: int, timeout: float = 5) -> bool:
    """Returns True if the port is NOT reachable (closed/filtered)."""
    try:
        with socket.create_connection((host, port), timeout=timeout):
            return False
    except (OSError, ConnectionRefusedError, ConnectionResetError):
        return True


def run_talosctl(ctx: CheckContext, *args: str, timeout: int = 30) -> subprocess.CompletedProcess:
    """Run talosctl with the correct config, endpoint, and node.

    All arguments are validated at CheckContext construction time:
    - ctx.talosctl: resolved to absolute path via shutil.which
    - ctx.talosconfig: validated against path allowlist
    - ctx.endpoint, ctx.node: validated against hostname/IP pattern
    - *args: hardcoded strings from check modules (not user input)
    """
    cmd = [
        ctx.talosctl,
        "--talosconfig", ctx.talosconfig,
        "--endpoints", ctx.endpoint,
        "--nodes", ctx.node,
        *args,
    ]
    return _safe_run(cmd, timeout)


def run_kubectl(ctx: CheckContext, *args: str, timeout: int = 30, stdin: str | None = None) -> subprocess.CompletedProcess:
    """Run kubectl with the correct kubeconfig.

    All arguments are validated at CheckContext construction time:
    - ctx.kubectl: resolved to absolute path via shutil.which
    - ctx.kubeconfig: validated against path allowlist
    - *args: hardcoded strings from check modules (not user input)
    """
    cmd = [ctx.kubectl, "--kubeconfig", ctx.kubeconfig, *args]
    return _safe_run(cmd, timeout, input=stdin)


def _safe_run(cmd: list[str], timeout: int, **kwargs) -> subprocess.CompletedProcess:
    """Run a subprocess, handling timeout and missing binary gracefully.

    Inputs are pre-validated by the calling functions — binary paths are
    resolved to absolute paths, hostnames/IPs are checked against allowlists,
    and file paths are validated for safe characters. See _validate_host(),
    _validate_path(), _validate_version(), _resolve_binary().
    """
    binary = cmd[0]
    try:
        # nosemgrep: python.lang.security.audit.dangerous-subprocess-use-audit
        return subprocess.run(cmd, capture_output=True, text=True, timeout=timeout, **kwargs)
    except subprocess.TimeoutExpired:
        return subprocess.CompletedProcess(
            "timeout", returncode=124, stdout="",
            stderr=f"command timed out after {timeout}s",
        )
    except FileNotFoundError:
        return subprocess.CompletedProcess(
            "not_found", returncode=127, stdout="",
            stderr=f"command not found: {binary}",
        )
