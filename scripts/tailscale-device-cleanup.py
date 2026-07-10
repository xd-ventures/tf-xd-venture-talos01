#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# Copyright Maciej Sawicki

"""Delete stale Tailscale devices matching a hostname before reinstall.

On reinstall, Tailscale registers a new device. If the old device still exists,
Tailscale appends a "-1" suffix to the hostname (e.g., "my-hostname" →
"my-hostname-1"), which breaks data.tailscale_device hostname lookups.

This script deletes devices that are stale incarnations of ONE node (#312):
  - a device whose hostname EXACTLY matches TS_CLEANUP_HOSTNAME is deleted
    unconditionally (it is this node's previous incarnation; the reinstall
    that this cleanup precedes is about to replace it), and
  - devices with a Tailscale dedup suffix (hostname-1, hostname-2, ...) are
    deleted only when it is safe: never if the name belongs to another
    cluster node (TS_CLEANUP_CLUSTER_HOSTNAMES), and never if the device was
    recently online (lastSeen within TS_CLEANUP_ONLINE_GRACE_MINUTES,
    default 10) or its lastSeen is unavailable — a stale dedup leftover is
    offline by definition, so anything alive is skipped fail-safe.

NODE NAMING CONSTRAINT (multi-node): node hostnames must not be numeric-suffix
extensions of each other (e.g. "talos-cp" and "talos-cp-2" may not coexist),
because a Tailscale dedup suffix is indistinguishable from such a sibling
name. The script exits with an error if TS_CLEANUP_CLUSTER_HOSTNAMES violates
this.

Requires:
  - TAILSCALE_OAUTH_CLIENT_ID and TAILSCALE_OAUTH_CLIENT_SECRET env vars
  - 'devices:core' scope on the OAuth client (for DELETE)
  - TS_CLEANUP_HOSTNAME env var (the expected hostname, without suffix)

Optional:
  - TS_CLEANUP_CLUSTER_HOSTNAMES: comma-separated hostnames of ALL cluster
    nodes (sibling-protection list; single-node setups pass just the one)
  - TS_CLEANUP_ONLINE_GRACE_MINUTES: recently-online threshold (default 10)

Exit codes:
  0 - success (including "nothing to delete")
  1 - error (auth failure, API error, missing env vars, naming conflict)
"""

import json
import os
import re
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from datetime import datetime, timedelta, timezone

DEFAULT_ONLINE_GRACE_MINUTES = 10

API_TIMEOUT = 10  # seconds — fail fast if Tailscale API is unreachable
API_RETRIES = 3  # transient-failure retries (URLError / 5xx) with short backoff


def _urlopen_with_retries(req, what: str):
    """urlopen with bounded retries for transient failures.

    A transient Tailscale API blip previously surfaced as a raw traceback and
    aborted 'tofu apply' mid-reinstall (#245). Retries cover network errors
    (URLError) and 5xx responses; 4xx errors are raised for callers to handle.
    """
    last_err = None
    for attempt in range(1, API_RETRIES + 1):
        try:
            return urllib.request.urlopen(req, timeout=API_TIMEOUT)
        except urllib.error.HTTPError as e:
            if e.code >= 500:
                last_err = e
            else:
                raise
        except urllib.error.URLError as e:
            last_err = e
        print(
            f"WARNING: {what} failed (attempt {attempt}/{API_RETRIES}): {last_err}",
            file=sys.stderr,
        )
        if attempt < API_RETRIES:
            time.sleep(3 * attempt)
    print(
        f"ERROR: {what} failed after {API_RETRIES} attempts: {last_err}. "
        "Check network connectivity to api.tailscale.com.",
        file=sys.stderr,
    )
    sys.exit(1)


def get_oauth_token(client_id: str, client_secret: str) -> str:
    """Exchange OAuth client credentials for an access token."""
    data = urllib.parse.urlencode({
        "client_id": client_id,
        "client_secret": client_secret,
        "grant_type": "client_credentials",
    }).encode()
    req = urllib.request.Request(
        "https://api.tailscale.com/api/v2/oauth/token",
        data=data,
        headers={"Content-Type": "application/x-www-form-urlencoded"},
    )
    try:
        resp = _urlopen_with_retries(req, "OAuth token request")
    except urllib.error.HTTPError as e:
        print(f"ERROR: OAuth token request failed: {e.code} {e.reason}", file=sys.stderr)
        if e.code == 401:
            print("Check TAILSCALE_OAUTH_CLIENT_ID and TAILSCALE_OAUTH_CLIENT_SECRET.", file=sys.stderr)
        sys.exit(1)
    return json.loads(resp.read())["access_token"]


def list_devices(token: str) -> list:
    """List all devices in the tailnet."""
    req = urllib.request.Request(
        "https://api.tailscale.com/api/v2/tailnet/-/devices?fields=default",
        headers={"Authorization": f"Bearer {token}"},
    )
    try:
        resp = _urlopen_with_retries(req, "device list request")
    except urllib.error.HTTPError as e:
        print(f"ERROR: device list request failed: {e.code} {e.reason}", file=sys.stderr)
        sys.exit(1)
    return json.loads(resp.read()).get("devices", [])


def delete_device(token: str, device_id: str) -> None:
    """Delete a device by ID."""
    req = urllib.request.Request(
        f"https://api.tailscale.com/api/v2/device/{device_id}",
        method="DELETE",
        headers={"Authorization": f"Bearer {token}"},
    )
    try:
        _urlopen_with_retries(req, f"device delete ({device_id})")
    except urllib.error.HTTPError as e:
        if e.code == 403:
            print(
                f"ERROR: 403 Forbidden deleting device {device_id}. "
                "Add 'devices:core' scope to the Tailscale OAuth client.",
                file=sys.stderr,
            )
            sys.exit(1)
        raise


def _parse_last_seen(value):
    """Parse the Tailscale API lastSeen timestamp (RFC 3339); None if unparseable."""
    if not value or not isinstance(value, str):
        return None
    try:
        return datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError:
        return None


def find_naming_conflicts(cluster_hostnames: list) -> list:
    """Return (base, extension) pairs where one node name numeric-suffix-extends another.

    Such pairs make a Tailscale dedup suffix indistinguishable from a sibling
    node, so they are a configuration error (see module docstring).
    """
    conflicts = []
    for base in cluster_hostnames:
        for other in cluster_hostnames:
            if other != base and re.fullmatch(rf"{re.escape(base)}-\d+", other):
                conflicts.append((base, other))
    return conflicts


def select_stale_devices(
    devices: list,
    hostname: str,
    cluster_hostnames: list = (),
    now: datetime = None,
    online_grace: timedelta = timedelta(minutes=DEFAULT_ONLINE_GRACE_MINUTES),
):
    """Split devices into (to_delete, skipped) for one node's cleanup.

    Exact hostname matches are always deleted (the node's own previous
    incarnation — this cleanup runs immediately before its reinstall).
    Dedup-suffixed matches (hostname-N) are deleted only when they are
    provably NOT a live machine: never when the name belongs to another
    cluster node, and never when the device was recently online or its
    lastSeen is unavailable. `skipped` holds (device, reason) tuples.
    """
    siblings = {h for h in cluster_hostnames if h and h != hostname}
    now = now or datetime.now(timezone.utc)
    suffixed = re.compile(rf"^{re.escape(hostname)}-\d+$")

    to_delete, skipped = [], []
    for d in devices:
        h = d.get("hostname", "")
        if h == hostname:
            to_delete.append(d)
        elif suffixed.match(h):
            if h in siblings:
                skipped.append((d, "name belongs to another cluster node"))
                continue
            last_seen = _parse_last_seen(d.get("lastSeen"))
            if last_seen is None:
                skipped.append((d, "lastSeen unavailable — not provably stale"))
            elif now - last_seen < online_grace:
                skipped.append((d, f"recently online (lastSeen {d.get('lastSeen')})"))
            else:
                to_delete.append(d)
    return to_delete, skipped


def main() -> None:
    hostname = os.environ.get("TS_CLEANUP_HOSTNAME", "")
    client_id = os.environ.get("TAILSCALE_OAUTH_CLIENT_ID", "")
    client_secret = os.environ.get("TAILSCALE_OAUTH_CLIENT_SECRET", "")
    cluster_hostnames = [
        h.strip()
        for h in os.environ.get("TS_CLEANUP_CLUSTER_HOSTNAMES", "").split(",")
        if h.strip()
    ]
    grace_minutes = int(
        os.environ.get("TS_CLEANUP_ONLINE_GRACE_MINUTES", DEFAULT_ONLINE_GRACE_MINUTES)
    )

    if not hostname:
        print("ERROR: TS_CLEANUP_HOSTNAME not set", file=sys.stderr)
        sys.exit(1)

    conflicts = find_naming_conflicts(cluster_hostnames or [hostname])
    if conflicts:
        for base, extension in conflicts:
            print(
                f"ERROR: node hostname '{extension}' is a numeric-suffix extension "
                f"of '{base}' — indistinguishable from a Tailscale dedup suffix. "
                "Rename one of the nodes (see script docstring).",
                file=sys.stderr,
            )
        sys.exit(1)

    if not client_id or not client_secret:
        print("TAILSCALE_OAUTH_CLIENT_ID/SECRET not set — skipping device cleanup")
        sys.exit(0)

    token = get_oauth_token(client_id, client_secret)
    devices = list_devices(token)
    stale, skipped = select_stale_devices(
        devices,
        hostname,
        cluster_hostnames,
        online_grace=timedelta(minutes=grace_minutes),
    )

    for d, reason in skipped:
        print(
            f"WARNING: skipping device {d.get('id', '?')} ({d.get('hostname', '?')}): {reason}",
            file=sys.stderr,
        )

    if not stale:
        print(f"No stale Tailscale devices found for '{hostname}'")
        return

    for d in stale:
        device_id = d["id"]
        device_hostname = d.get("hostname", "unknown")
        print(f"Deleting stale Tailscale device: {device_id} ({device_hostname})")
        delete_device(token, device_id)
        print("  deleted.")

    print(f"Cleaned up {len(stale)} stale device(s).")


if __name__ == "__main__":
    main()
