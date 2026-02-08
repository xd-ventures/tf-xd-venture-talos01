# OVH Object Storage Backend Configuration
#
# This file configures Terraform remote state storage using OVH Object Storage (S3-compatible).
# See ADR-0006 for decision rationale.
#
# SETUP INSTRUCTIONS:
# 1. Create an OVH Object Storage container via the Control Panel or API
# 2. Generate S3 credentials: Control Panel -> Users & Roles -> Generate S3 Credentials
# 3. Copy backend.tfvars.example to backend.tfvars and fill in your values
# 4. Initialize with: tofu init -backend-config=backend.tfvars
#
# MIGRATION FROM LOCAL STATE:
# If you have existing local state, run:
#   tofu init -backend-config=backend.tfvars -migrate-state

# terraform {
#   backend "s3" {
#     # These values should be provided via backend.tfvars file
#     # Do NOT commit backend.tfvars to version control
#
#     # OVH Object Storage endpoint (varies by region)
#     # GRA: s3.gra.io.cloud.ovh.net
#     # SBG: s3.sbg.io.cloud.ovh.net
#     # DE:  s3.de.io.cloud.ovh.net
#     # UK:  s3.uk.io.cloud.ovh.net
#     # BHS: s3.bhs.io.cloud.ovh.net
#     # WAW: s3.waw.io.cloud.ovh.net
#     endpoint = ""  # Set in backend.tfvars
#
#     # Container name (create this first in OVH Control Panel)
#     bucket = ""  # Set in backend.tfvars
#
#     # State file path within the container
#     key = "talos-cluster/terraform.tfstate"
#
#     # OVH Object Storage requires these settings
#     skip_credentials_validation = true
#     skip_region_validation      = true
#     skip_metadata_api_check     = true
#     skip_requesting_account_id  = true
#     skip_s3_checksum            = true
#     use_path_style              = true
#
#     # Region (can be any value, OVH ignores it but Terraform requires it)
#     region = "gra"
#
#     # S3 credentials - set via backend.tfvars or environment variables:
#     # AWS_ACCESS_KEY_ID (from OVH S3 credentials)
#     # AWS_SECRET_ACCESS_KEY (from OVH S3 credentials)
#   }
# }

# NOTE: Backend configuration is commented out by default.
# To enable remote state:
# 1. Uncomment the backend "s3" block above
# 2. Create backend.tfvars with your credentials
# 3. Run: tofu init -backend-config=backend.tfvars

# For local development without remote state, leave the backend commented.
# The state will be stored locally in terraform.tfstate.
