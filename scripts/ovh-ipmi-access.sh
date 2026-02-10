#!/bin/bash
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
    SERVICE_NAME=$(tofu output -raw server_id 2>/dev/null || echo "")
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
    # Check IPMI availability
    print("Checking IPMI availability...")
    ipmi = client.get(f'/dedicated/server/{service_name}/features/ipmi')
    print(f"IPMI available: {ipmi.get('activated', False)}")
    print(f"KVM available: {ipmi.get('supportedFeatures', {}).get('kvmipHtml5', False)}")
    print(f"SOL available: {ipmi.get('supportedFeatures', {}).get('serialOverLanSshKey', False)}")

    if not ipmi.get('activated'):
        print("\n❌ IPMI is not activated on this server")
        sys.exit(1)

    # Request HTML5 KVM access
    print("\nRequesting KVM access...")
    try:
        result = client.post(
            f'/dedicated/server/{service_name}/features/ipmi/access',
            type='kvmipHtml5',
            ttl=30  # minutes
        )
        print(f"KVM access requested. Check OVH console for access URL.")
    except Exception as e:
        print(f"KVM request failed: {e}")

    # For automated access, use ovh-kvm tool:
    print("\n" + "="*50)
    print("For command-line KVM access, install ovh-kvm:")
    print("  pip install ovh-kvm")
    print("  git clone https://github.com/amilabs/ovh-kvm")
    print("")
    print("Then run:")
    print(f"  python ovh-kvm.py {service_name}")
    print("="*50)

except Exception as e:
    print(f"Error: {e}", file=sys.stderr)
    sys.exit(1)
EOF
