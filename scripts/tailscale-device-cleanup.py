#!/usr/bin/env python3
"""Delete stale Tailscale devices matching a hostname before reinstall.

On reinstall, Tailscale registers a new device. If the old device still exists,
Tailscale appends a "-1" suffix to the hostname (e.g., "talos-xd-venture" →
"talos-xd-venture-1"), which breaks data.tailscale_device hostname lookups.

This script deletes any existing devices whose hostname matches exactly or has
a numeric suffix (hostname-1, hostname-2, etc.) so the new device registers
with the intended hostname.

Requires:
  - TAILSCALE_OAUTH_CLIENT_ID and TAILSCALE_OAUTH_CLIENT_SECRET env vars
  - 'devices:core' scope on the OAuth client (for DELETE)
  - TS_CLEANUP_HOSTNAME env var (the expected hostname, without suffix)

Exit codes:
  0 - success (including "nothing to delete")
  1 - error (auth failure, API error, missing env vars)
"""

import json
import os
import re
import sys
import urllib.error
import urllib.parse
import urllib.request

API_TIMEOUT = 10  # seconds — fail fast if Tailscale API is unreachable


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
        resp = urllib.request.urlopen(req, timeout=API_TIMEOUT)
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
    resp = urllib.request.urlopen(req, timeout=API_TIMEOUT)
    return json.loads(resp.read()).get("devices", [])


def delete_device(token: str, device_id: str) -> None:
    """Delete a device by ID."""
    req = urllib.request.Request(
        f"https://api.tailscale.com/api/v2/device/{device_id}",
        method="DELETE",
        headers={"Authorization": f"Bearer {token}"},
    )
    try:
        urllib.request.urlopen(req, timeout=API_TIMEOUT)
    except urllib.error.HTTPError as e:
        if e.code == 403:
            print(
                f"ERROR: 403 Forbidden deleting device {device_id}. "
                "Add 'devices:core' scope to the Tailscale OAuth client.",
                file=sys.stderr,
            )
            sys.exit(1)
        raise


def find_stale_devices(devices: list, hostname: str) -> list:
    """Find devices matching hostname exactly or with numeric suffix (e.g., -1, -2)."""
    pattern = re.compile(rf"^{re.escape(hostname)}(-\d+)?$")
    return [d for d in devices if pattern.match(d.get("hostname", ""))]


def main() -> None:
    hostname = os.environ.get("TS_CLEANUP_HOSTNAME", "")
    client_id = os.environ.get("TAILSCALE_OAUTH_CLIENT_ID", "")
    client_secret = os.environ.get("TAILSCALE_OAUTH_CLIENT_SECRET", "")

    if not hostname:
        print("ERROR: TS_CLEANUP_HOSTNAME not set", file=sys.stderr)
        sys.exit(1)

    if not client_id or not client_secret:
        print("TAILSCALE_OAUTH_CLIENT_ID/SECRET not set — skipping device cleanup")
        sys.exit(0)

    token = get_oauth_token(client_id, client_secret)
    devices = list_devices(token)
    stale = find_stale_devices(devices, hostname)

    if not stale:
        print(f"No stale Tailscale devices found for '{hostname}'")
        return

    for d in stale:
        device_id = d["id"]
        device_hostname = d.get("hostname", "unknown")
        print(f"Deleting stale Tailscale device: {device_id} ({device_hostname})")
        delete_device(token, device_id)
        print(f"  deleted.")

    print(f"Cleaned up {len(stale)} stale device(s).")


if __name__ == "__main__":
    main()
