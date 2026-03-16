#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
# Copyright xd-ventures contributors

# OVH Server Status Check
#
# Usage: ./ovh-server-status.sh [service_name]
#
# Requires OVH CLI configured or environment variables:
# - OVH_ENDPOINT
# - OVH_APPLICATION_KEY
# - OVH_APPLICATION_SECRET
# - OVH_CONSUMER_KEY

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
  echo "Or run from terraform directory to auto-detect"
  exit 1
fi

echo "Checking server: $SERVICE_NAME"
echo "================================"

# Use Python OVH SDK for API calls
export SERVICE_NAME
python3 << 'EOF'
import ovh
import json
import os
import sys

service_name = os.environ['SERVICE_NAME']

try:
    client = ovh.Client()

    # Get server details
    server = client.get(f'/dedicated/server/{service_name}')
    print(f"Server Name: {server.get('name', 'N/A')}")
    print(f"State: {server.get('state', 'N/A')}")
    print(f"IP: {server.get('ip', 'N/A')}")
    print(f"Boot Mode: {server.get('bootId', 'N/A')}")

    # Get recent tasks
    print("\nRecent Tasks:")
    tasks = client.get(f'/dedicated/server/{service_name}/task')
    for task_id in tasks[-5:]:
        task = client.get(f'/dedicated/server/{service_name}/task/{task_id}')
        print(f"  [{task_id}] {task.get('function', 'N/A')}: {task.get('status', 'N/A')}")
        if task.get('comment'):
            print(f"           Comment: {task.get('comment')}")

except Exception as e:
    print(f"Error: {e}", file=sys.stderr)
    sys.exit(1)
EOF

echo ""
echo "================================"
