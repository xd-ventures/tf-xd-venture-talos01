# ADR-0006: Remote State Backend

## Status
Accepted

## Date
2026-02-08

## Context
Terraform/OpenTofu state must be stored securely. Local state is not acceptable for production or collaboration.

### Challenge
- State contains sensitive data (secrets, kubeconfig)
- Need locking for concurrent access prevention
- Must be reliable and durable
- Prefer self-hosted over SaaS dependencies

### Considered Options

#### Option 1: Local State
- Default Terraform behavior
- No collaboration support
- No locking
- Risk of state loss
- **Rejected**: Not suitable for production

#### Option 2: Terraform Cloud
- HashiCorp managed service
- Built-in locking and versioning
- Free tier available
- **Rejected**: Licensing/pricing concerns, SaaS dependency

#### Option 3: AWS S3 + DynamoDB
- Proven, widely used
- Native locking via DynamoDB
- Requires AWS account
- **Rejected**: Additional cloud provider dependency

#### Option 4: OVH Object Storage
- S3-compatible API
- Already using OVH for infrastructure
- Versioning support
- No native locking (limitation)
- **Selected**

## Decision
Use OVH Object Storage as S3-compatible backend.

### Implementation
```hcl
# backend.tf
terraform {
  backend "s3" {
    bucket = "my-terraform-state"
    key    = "talos01/terraform.tfstate"
    region = "gra"

    endpoints = {
      s3 = "https://s3.gra.io.cloud.ovh.net"
    }

    skip_credentials_validation = true
    skip_region_validation      = true
    skip_requesting_account_id  = true
    skip_metadata_api_check     = true
    skip_s3_checksum           = true
    use_path_style             = true
  }
}
```

### Environment Variables
```bash
export AWS_ACCESS_KEY_ID="your_access_key"
export AWS_SECRET_ACCESS_KEY="your_secret_key"
```

## Consequences

### Positive
- Single cloud provider (OVH)
- S3-compatible, widely supported
- Versioning enables state recovery
- No additional cost (included with OVH)

### Negative
- No native state locking
- Must rely on process (single operator) for now

### Locking Mitigation
- Single-operator workflow (acceptable for showcase)
- Future: Consider OpenTACO for CI/CD-based locking
- Document limitation in README

### Bucket Configuration
1. Create bucket with versioning enabled
2. Enable object lock for additional protection (optional)
3. Restrict access to authorized users only

## References
- [OVH Object Storage as Terraform Backend](https://blog.ovhcloud.com/using-ovhcloud-s3-compatible-object-storage-as-terraform-backend-to-store-your-terraform-opentofu-states/)
- [OpenTofu Remote State](https://opentofu.org/docs/language/state/remote/)
