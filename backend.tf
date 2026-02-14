# S3-Compatible Remote State Backend
#
# This backend uses any S3-compatible object storage (OVH, AWS, MinIO, etc.).
# See ADR-0006 for decision rationale and ADR-0010 for migration procedure.
#
# IMPORTANT: OVH Object Storage does NOT support state locking (no DynamoDB
# equivalent). Use process controls to prevent concurrent operations.
# See ADR-0010 for mitigations.
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

    # S3-compatibility flags required for OVH Object Storage.
    # These are also safe to keep when using AWS S3 or other providers.
    skip_credentials_validation = true
    skip_region_validation      = true
    skip_metadata_api_check     = true
    skip_requesting_account_id  = true
    skip_s3_checksum            = true
    use_path_style              = true
  }
}
