#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
# Copyright Maciej Sawicki

# Request OVH IPMI/KVM console access
#
# Usage: ./ovh-ipmi-access.sh [service_name]
#
# This will request temporary IPMI access for:
# - Serial over LAN (SOL) console
# - KVM-over-IP (if supported)

set -euo pipefail

SERVICE_NAME="${1:-}"

# If no service name provided, try to get from terraform output
if [ -z "$SERVICE_NAME" ]; then
  if command -v tofu &> /dev/null; then
    SERVICE_NAME=$(tofu -chdir=infra output -raw server_id 2>/dev/null || echo "")
  fi
fi

if [ -z "$SERVICE_NAME" ]; then
  echo "Usage: $0 <service_name>"
  exit 1
fi

echo "Requesting IPMI access for $SERVICE_NAME..."
echo "============================================"

export SERVICE_NAME
python3 << 'EOF'
import ovh
import os
import time
import sys

client = ovh.Client()
service_name = os.environ['SERVICE_NAME']

try:
    # Check IPMI availability. Feature keys and access types come from the
    # OVH API schema (IpmiAccessTypeEnum) — the old values ('kvmipHtml5',
    # ttl=30) were invalid and the request failed on every run (#245).
    print("Checking IPMI availability...")
    ipmi = client.get(f'/dedicated/server/{service_name}/features/ipmi')
    features = ipmi.get('supportedFeatures', {})
    kvm_supported = features.get('kvmipHtml5URL', False)
    sol_supported = features.get('serialOverLanSshKey', False)
    print(f"IPMI activated: {ipmi.get('activated', False)}")
    print(f"KVM (kvmipHtml5URL) supported: {kvm_supported}")
    print(f"SOL (serialOverLanSshKey) supported: {sol_supported}")

    if not ipmi.get('activated'):
        print("\n\u274c IPMI is not activated on this server", file=sys.stderr)
        sys.exit(1)
    if not kvm_supported:
        print("\n\u274c KVM-over-IP (kvmipHtml5URL) is not supported on this server", file=sys.stderr)
        sys.exit(1)

    # Request HTML5 KVM access. ttl must be in CacheTTLEnum {1,3,5,10,15}.
    print("\nRequesting KVM access (ttl 15 min)...")
    client.post(
        f'/dedicated/server/{service_name}/features/ipmi/access',
        type='kvmipHtml5URL',
        ttl=15,
    )

    # The access URL is generated asynchronously — poll for it.
    print("Waiting for the access URL...")
    deadline = time.time() + 120
    while time.time() < deadline:
        try:
            access = client.get(
                f'/dedicated/server/{service_name}/features/ipmi/access',
                type='kvmipHtml5URL',
            )
            value = access.get('value')
            if value:
                expiry = access.get('expiration', 'unknown')
                print(f"\n\u2705 KVM console URL (expires {expiry}):\n\n  {value}\n")
                print("Open it in a browser for the HTML5 console. For LLM-driven")
                print("console screenshots use ovh-ikvm-mcp (see CLAUDE.md / README).")
                sys.exit(0)
        except ovh.exceptions.APIError:
            pass  # not generated yet
        time.sleep(5)

    print("\n\u274c Timed out waiting for the KVM access URL (120s)", file=sys.stderr)
    sys.exit(1)

except Exception as e:
    print(f"Error: {e}", file=sys.stderr)
    sys.exit(1)
EOF
