#!/usr/bin/env python3
"""OVH Dedicated Server Reinstall via v2 API.

Calls POST /dedicated/server/{sn}/reinstall (v2 endpoint) and polls the
resulting task until completion. The v1 endpoint used by the OVH Terraform
provider (ovh_dedicated_server_reinstall_task) returns HTTP 500 as of
provider v2.11.0. This script is the workaround.

See: https://github.com/xd-ventures/tf-xd-venture-talos01/issues/130

Environment variables (set by Terraform local-exec):
    OVH_REINSTALL_SERVICE_NAME  — server service name (e.g. nsXXXXXX.ip-XX-XX-XX.eu)
    OVH_REINSTALL_HOSTNAME      — hostname for the installation
    OVH_REINSTALL_IMAGE_URL     — Talos image URL
    OVH_REINSTALL_IMAGE_TYPE    — image type (qcow2 or raw)
    OVH_REINSTALL_EFI_PATH      — EFI bootloader path
    OVH_REINSTALL_USER_DATA     — base64-encoded config drive user data
    OVH_REINSTALL_INSTANCE_ID   — unique instance-id for config drive metadata
    OVH_REINSTALL_TIMEOUT       — timeout in seconds (default: 1800)

OVH API credentials are read from standard OVH environment variables:
    OVH_ENDPOINT, OVH_APPLICATION_KEY, OVH_APPLICATION_SECRET, OVH_CONSUMER_KEY
"""

import json
import os
import sys
import time

import ovh


def main():
    service_name = os.environ["OVH_REINSTALL_SERVICE_NAME"]
    hostname = os.environ["OVH_REINSTALL_HOSTNAME"]
    image_url = os.environ["OVH_REINSTALL_IMAGE_URL"]
    image_type = os.environ["OVH_REINSTALL_IMAGE_TYPE"]
    efi_path = os.environ["OVH_REINSTALL_EFI_PATH"]
    user_data = os.environ["OVH_REINSTALL_USER_DATA"]
    instance_id = os.environ["OVH_REINSTALL_INSTANCE_ID"]
    timeout = int(os.environ.get("OVH_REINSTALL_TIMEOUT", "1800"))

    client = ovh.Client()

    # --- Call v2 reinstall endpoint ---
    print(f"Reinstalling {service_name} via v2 API...")
    print(f"  hostname:   {hostname}")
    print(f"  image_type: {image_type}")
    print(f"  image_url:  {image_url[:80]}...")

    result = client.post(
        f"/dedicated/server/{service_name}/reinstall",
        operatingSystem="byoi_64",
        customizations={
            "hostname": hostname,
            "imageURL": image_url,
            "imageType": image_type,
            "efiBootloaderPath": efi_path,
            "configDriveUserData": user_data,
            "configDriveMetadata": {
                "instance-id": instance_id,
                "local-hostname": hostname,
            },
        },
    )

    task_id = result.get("taskId") or result.get("id")
    if not task_id:
        print(f"ERROR: No task ID in response: {json.dumps(result)}", file=sys.stderr)
        sys.exit(1)

    print(f"Reinstall task created: {task_id}")

    # --- Poll task until completion ---
    start = time.time()
    while True:
        elapsed = int(time.time() - start)

        try:
            task = client.get(f"/dedicated/server/{service_name}/task/{task_id}")
        except ovh.exceptions.ResourceNotFoundError:
            # Task may take a moment to become queryable
            if elapsed < 30:
                time.sleep(5)
                continue
            print(f"ERROR: Task {task_id} not found after {elapsed}s", file=sys.stderr)
            sys.exit(1)

        status = task.get("status", "unknown")
        comment = task.get("comment", "")
        progress = f" - {comment}" if comment else ""

        print(f"[{elapsed}s] status={status}{progress}")

        if status == "done":
            print(f"Reinstall completed in {elapsed}s")
            return

        if status in ("error", "cancelled", "canceled"):
            print(
                f"ERROR: Reinstall failed with status={status}: {comment}",
                file=sys.stderr,
            )
            sys.exit(1)

        if elapsed > timeout:
            print(f"ERROR: Timeout after {timeout}s", file=sys.stderr)
            sys.exit(1)

        time.sleep(15)


if __name__ == "__main__":
    main()
