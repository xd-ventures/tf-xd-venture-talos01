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

    # Wait for reboot to complete
    print("Waiting for reboot to complete...")
    for i in range(60):  # 10 minutes max
        task = client.get(f'/dedicated/server/{service_name}/task/{task_id}')
        status = task.get('status')
        print(f"  Status: {status}")

        if status == 'done':
            print("\n✅ Server is rebooting to harddisk!")
            break
        elif status == 'error':
            print(f"Reboot failed: {task.get('comment')}")
            sys.exit(1)

        time.sleep(10)

    # Get server IP
    server = client.get(f'/dedicated/server/{service_name}')
    print(f"\nServer IP: {server.get('ip')}")
    print("Server should be available shortly.")

except Exception as e:
    print(f"Error: {e}", file=sys.stderr)
    sys.exit(1)
EOF
