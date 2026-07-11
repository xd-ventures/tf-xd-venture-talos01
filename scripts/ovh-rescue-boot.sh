#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
# Copyright Maciej Sawicki

# Boot OVH server into rescue mode
#
# Usage: ./ovh-rescue-boot.sh [service_name]
#
# This will:
# 1. Set boot mode to rescue
# 2. Trigger a hard reboot
# 3. Wait for server to come online
# 4. Display SSH credentials

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

echo "Booting $SERVICE_NAME into rescue mode..."
echo "=========================================="

export SERVICE_NAME
python3 << 'EOF'
import ovh
from ovh.exceptions import ResourceNotFoundError
import os
import time
import sys

client = ovh.Client()
service_name = os.environ['SERVICE_NAME']

try:
    # Get rescue boot ID
    print("Finding rescue boot option...")
    boots = client.get(f'/dedicated/server/{service_name}/boot', bootType='rescue')

    if not boots:
        print("No rescue boot available!")
        sys.exit(1)

    rescue_boot_id = boots[0]
    print(f"Rescue boot ID: {rescue_boot_id}")

    # Set boot to rescue
    print("Setting boot mode to rescue...")
    client.put(f'/dedicated/server/{service_name}', bootId=rescue_boot_id)

    # Trigger reboot
    print("Triggering hard reboot...")
    result = client.post(f'/dedicated/server/{service_name}/reboot')
    task_id = result.get('taskId')
    print(f"Reboot task: {task_id}")

    # Wait for reboot task to complete. Loop exhaustion is a FAILURE —
    # previously it fell through and reported success (#245). Transient API
    # errors are retried until the deadline instead of aborting.
    print("Waiting for reboot task to complete...")
    deadline = time.time() + 600  # 10 minutes
    completed = False
    while time.time() < deadline:
        try:
            task = client.get(f'/dedicated/server/{service_name}/task/{task_id}')
        except ResourceNotFoundError:
            print(f"\n\u274c Task {task_id} not found (404)", file=sys.stderr)
            sys.exit(1)
        except Exception as e:
            print(f"  API error (will retry): {e}")
            time.sleep(10)
            continue
        status = task.get('status')
        print(f"  Status: {status}")

        if status == 'done':
            completed = True
            break
        elif status in ('error', 'cancelled', 'canceled', 'ovhError', 'customerError'):
            print(f"Reboot task {status}: {task.get('comment')}")
            sys.exit(1)

        time.sleep(10)

    if not completed:
        print("\n\u274c Reboot task did not complete within 10 minutes", file=sys.stderr)
        sys.exit(1)

    # Get server info including rescue credentials
    print("\nServer is rebooting into rescue mode.")
    print("Check your email for rescue credentials, or use:")
    print(f"  ssh root@<server-ip>")
    print("\nNote: Rescue password is typically sent via email.")

    # Get server IP
    server = client.get(f'/dedicated/server/{service_name}')
    print(f"\nServer IP: {server.get('ip')}")

except Exception as e:
    print(f"Error: {e}", file=sys.stderr)
    sys.exit(1)
EOF

echo ""
echo "=========================================="
echo "After rescue work, restore normal boot with:"
echo "  ./scripts/ovh-normal-boot.sh"
