#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
# Copyright Maciej Sawicki

# Restore OVH server to normal boot mode
#
# Usage: ./ovh-normal-boot.sh [service_name]
#
# This will:
# 1. Set boot mode to harddisk
# 2. Trigger a hard reboot

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

echo "Restoring $SERVICE_NAME to normal boot mode..."
echo "================================================"

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
    # Get harddisk boot ID
    print("Finding harddisk boot option...")
    boots = client.get(f'/dedicated/server/{service_name}/boot', bootType='harddisk')

    if not boots:
        print("No harddisk boot available!")
        sys.exit(1)

    hdd_boot_id = boots[0]
    print(f"Harddisk boot ID: {hdd_boot_id}")

    # Set boot to harddisk
    print("Setting boot mode to harddisk...")
    client.put(f'/dedicated/server/{service_name}', bootId=hdd_boot_id)

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

    # Get server IP
    server = client.get(f'/dedicated/server/{service_name}')
    print(f"\nServer IP: {server.get('ip')}")
    print("Server should be available shortly.")

except Exception as e:
    print(f"Error: {e}", file=sys.stderr)
    sys.exit(1)
EOF
