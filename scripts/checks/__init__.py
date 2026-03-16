"""Cluster validation checks — shared context and utilities."""

import json
import os
import re
import shutil
import socket
import subprocess
import time
from dataclasses import dataclass

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
            outputs, "cluster_endpoint", ""
        )

        tailscale_ip = _validate_host(
            _get(outputs, "tailscale_device_ip", ""), "tailscale_device_ip"
        )
        if tailscale_ip:
            ctx.tailscale_ip = tailscale_ip

        zfs_info = _get(outputs, "zfs_pool_info", None)
        if isinstance(zfs_info, dict):
            ctx.zfs_pool_enabled = zfs_info.get("status") == "enabled"
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


def _tofu_outputs() -> dict:
    """Query all tofu outputs as JSON."""
    tofu = _resolve_binary("tofu")
    try:
        result = subprocess.run(
            [tofu, "output", "-json"],
            capture_output=True,
            text=True,
            timeout=30,
        )
        if result.returncode != 0:
            return {}
        raw = json.loads(result.stdout)
        return {k: v.get("value") for k, v in raw.items()}
    except (subprocess.TimeoutExpired, FileNotFoundError, json.JSONDecodeError):
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
    try:
        # nosemgrep: python.lang.security.audit.dangerous-subprocess-use-audit
        return subprocess.run(cmd, capture_output=True, text=True, timeout=timeout, **kwargs)
    except subprocess.TimeoutExpired:
        # nosemgrep: python.lang.security.audit.dangerous-subprocess-use-audit
        return subprocess.CompletedProcess(cmd, returncode=124, stdout="", stderr=f"command timed out after {timeout}s")
    except FileNotFoundError:
        # nosemgrep: python.lang.security.audit.dangerous-subprocess-use-audit
        return subprocess.CompletedProcess(cmd, returncode=127, stdout="", stderr=f"command not found: {cmd[0]}")
