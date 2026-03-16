#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
# Copyright Maciej Sawicki

# Wait for OVH task to complete
#
# Usage: ./ovh-wait-task.sh <task_id> [service_name] [timeout_seconds]
#
# Requires OVH CLI configured or environment variables

set -euo pipefail

TASK_ID="${1:-}"
SERVICE_NAME="${2:-}"
TIMEOUT="${3:-1800}"  # 30 minutes default

if [ -z "$TASK_ID" ]; then
  echo "Usage: $0 <task_id> [service_name] [timeout_seconds]"
  exit 1
fi

# If no service name provided, try to get from terraform output
if [ -z "$SERVICE_NAME" ]; then
  if command -v tofu &> /dev/null; then
    SERVICE_NAME=$(tofu output -raw server_id 2>/dev/null || echo "")
  fi
fi

if [ -z "$SERVICE_NAME" ]; then
  echo "Error: service_name required"
  exit 1
fi

echo "Waiting for task $TASK_ID on $SERVICE_NAME (timeout: ${TIMEOUT}s)"
echo "================================================================"

export SERVICE_NAME TASK_ID TIMEOUT
python3 << 'EOF'
import ovh
import os
import time
import sys

client = ovh.Client()
service_name = os.environ['SERVICE_NAME']
task_id = int(os.environ['TASK_ID'])
timeout = int(os.environ['TIMEOUT'])
start_time = time.time()

print(f"Monitoring task {task_id}...")

while True:
    try:
        task = client.get(f'/dedicated/server/{service_name}/task/{task_id}')
        status = task.get('status', 'unknown')
        function = task.get('function', 'unknown')
        comment = task.get('comment', '')

        elapsed = int(time.time() - start_time)
        print(f"[{elapsed}s] {function}: {status}" + (f" - {comment}" if comment else ""))

        if status == 'done':
            print("\n✅ Task completed successfully!")
            sys.exit(0)
        elif status == 'error':
            print(f"\n❌ Task failed: {comment}")
            sys.exit(1)
        elif status in ['cancelled', 'canceled']:
            print("\n⚠️ Task was cancelled")
            sys.exit(1)

        if time.time() - start_time > timeout:
            print(f"\n⏰ Timeout after {timeout}s")
            sys.exit(1)

        time.sleep(10)

    except Exception as e:
        print(f"Error checking task: {e}")
        time.sleep(10)
EOF
