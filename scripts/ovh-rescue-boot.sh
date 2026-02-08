#!/bin/bash
# Boot OVH server into rescue mode
#
# Usage: ./ovh-rescue-boot.sh [service_name]
#
# This will:
# 1. Set boot mode to rescue
# 2. Trigger a hard reboot
# 3. Wait for server to come online
# 4. Display SSH credentials

set -e

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

echo "Booting $SERVICE_NAME into rescue mode..."
echo "=========================================="

python3 << EOF
import ovh
import time
import sys

client = ovh.Client()
service_name = "${SERVICE_NAME}"

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

    # Wait for reboot to complete
    print("Waiting for reboot to complete...")
    for i in range(60):  # 10 minutes max
        task = client.get(f'/dedicated/server/{service_name}/task/{task_id}')
        status = task.get('status')
        print(f"  Status: {status}")

        if status == 'done':
            break
        elif status == 'error':
            print(f"Reboot failed: {task.get('comment')}")
            sys.exit(1)

        time.sleep(10)

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
