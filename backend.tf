# OVH Object Storage Backend Configuration
#
# This file configures Terraform remote state storage using OVH Object Storage (S3-compatible).
# See ADR-0006 for decision rationale and ADR-0010 for migration procedure.
#
# IMPORTANT: OVH Object Storage does NOT support state locking (no DynamoDB equivalent).
# Use process controls to prevent concurrent operations. See ADR-0010 for mitigations.
#
# SETUP INSTRUCTIONS:
# 1. Create an OVH Object Storage container with versioning enabled
# 2. Generate S3 credentials: Control Panel -> Users & Roles -> Generate S3 Credentials
# 3. Set environment variables (recommended over backend.tfvars):
#      export AWS_ACCESS_KEY_ID="<your-access-key>"
#      export AWS_SECRET_ACCESS_KEY="<your-secret-key>"
# 4. Uncomment the backend block below
# 5. Initialize with: tofu init -migrate-state
#
# ROLLBACK:
# To revert to local state, comment out the backend block and run:
#   tofu init -migrate-state

# terraform {
#   backend "s3" {
#     # Container/bucket name (create in OVH Control Panel first)
#     bucket = "xd-venture-terraform-state"
#
#     # State file path within the container
#     key = "talos-cluster/terraform.tfstate"
#
#     # Region (required by Terraform, but OVH uses endpoint for routing)
#     region = "gra"
#
#     # OVH Object Storage endpoint (OpenTofu 1.6+ / Terraform 1.6+ syntax)
#     # Available regions:
#     #   GRA (Gravelines, France): https://s3.gra.io.cloud.ovh.net
#     #   SBG (Strasbourg, France): https://s3.sbg.io.cloud.ovh.net
#     #   DE  (Frankfurt, Germany): https://s3.de.io.cloud.ovh.net
#     #   UK  (London, UK):         https://s3.uk.io.cloud.ovh.net
#     #   BHS (Beauharnois, Canada): https://s3.bhs.io.cloud.ovh.net
#     #   WAW (Warsaw, Poland):     https://s3.waw.io.cloud.ovh.net
#     endpoints = {
#       s3 = "https://s3.gra.io.cloud.ovh.net"
#     }
#
#     # OVH Object Storage compatibility settings (all required)
#     skip_credentials_validation = true
#     skip_region_validation      = true
#     skip_metadata_api_check     = true
#     skip_requesting_account_id  = true
#     skip_s3_checksum            = true
#     use_path_style              = true
#
#     # Encryption: OVH supports SSE-S3 (AES-256)
#     # Enable via bucket policy or on upload
#     # encrypt = true  # Uncomment if bucket has encryption enabled
#
#     # Credentials: Set via environment variables (recommended):
#     #   AWS_ACCESS_KEY_ID     = "<ovh-s3-access-key>"
#     #   AWS_SECRET_ACCESS_KEY = "<ovh-s3-secret-key>"
#     # DO NOT use access_key/secret_key in this file or backend.tfvars
#   }
# }

# NOTE: Backend configuration is commented out by default.
# To enable remote state, follow the migration procedure in ADR-0010.
# For local development without remote state, leave the backend commented.
