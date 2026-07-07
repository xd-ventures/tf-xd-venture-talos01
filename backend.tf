# SPDX-License-Identifier: Apache-2.0
# Copyright Maciej Sawicki

# S3-Compatible Remote State Backend
#
# This backend uses any S3-compatible object storage (OVH, AWS, MinIO, etc.).
# See ADR-0006 for decision rationale, ADR-0010 for migration procedure, and
# ADR-0014 for the locking/GitOps architecture.
#
# STATE LOCKING: native S3 locking via use_lockfile (OpenTofu >= 1.10, S3
# conditional writes). OVH Object Storage supports this since ~2026-06 on
# io.cloud.ovh.net endpoints — verified on this bucket: a concurrent apply
# fails with 412 PreconditionFailed while a .tflock object is held (#278).
# No DynamoDB needed. Requires bucket versioning (enabled) as the state
# recovery safety net.
#
# USAGE:
#   Maintainers / deployers (with backend credentials):
#     cp backend.tfvars.example backend.tfvars   # fill in your values
#     export AWS_ACCESS_KEY_ID="..."
#     export AWS_SECRET_ACCESS_KEY="..."
#     tofu init -backend-config=backend.tfvars
#
#   Contributors (no credentials needed):
#     tofu init -backend=false
#
# ROLLBACK:
#   To migrate back to local state:
#     tofu init -migrate-state -backend=false

terraform {
  backend "s3" {
    # State file path within the bucket
    key = "talos-cluster/terraform.tfstate"

    # Enable server-side encryption (SSE-S3) for state at rest.
    # State contains cluster PKI material and kubeconfig credentials.
    encrypt = true

    # Native S3 state locking via conditional writes (If-None-Match).
    # Writes <key>.tflock during operations; concurrent runs fail fast
    # with 412 PreconditionFailed. See ADR-0014 / #278.
    use_lockfile = true

    # S3-compatibility flags required for OVH Object Storage.
    # These are also safe to keep when using AWS S3 or other providers.
    # skip_s3_checksum is load-bearing for locking on non-AWS S3: newer
    # AWS SDKs send checksums that third-party implementations reject
    # (see opentofu/opentofu#2605 — same flag keeps Hetzner working).
    skip_credentials_validation = true
    skip_region_validation      = true
    skip_metadata_api_check     = true
    skip_requesting_account_id  = true
    skip_s3_checksum            = true
    use_path_style              = true
  }
}
