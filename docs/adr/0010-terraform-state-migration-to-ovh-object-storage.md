# ADR-0010: Terraform State Migration to OVH Object Storage

## Status

Accepted

## Date

2026-02-08

## Context

This ADR documents the implementation plan for migrating Terraform state from local storage to OVH Object Storage, as decided in ADR-0006. While ADR-0006 established the strategic decision to use OVH Object Storage, this ADR focuses on the operational aspects of the migration.

### Current State

- State file: `terraform.tfstate` (192KB, actively managed)
- Backup files: Multiple `.backup` files present
- Storage: Local filesystem only
- Locking: None
- Collaboration: Single operator

### Business Drivers

1. **State durability**: Local disk failure would mean state loss and potential orphaned resources
2. **Team readiness**: Prepare for future collaboration even if solo now
3. **Operational hygiene**: State should survive laptop loss/replacement
4. **Audit trail**: Versioning provides history of infrastructure changes

### Technical Context

OVH Object Storage is S3-compatible but has limitations compared to AWS S3:

| Feature | AWS S3 | OVH Object Storage |
|---------|--------|-------------------|
| S3 API compatibility | Native | Compatible (v2/v4 signing) |
| Server-side encryption | SSE-S3, SSE-KMS, SSE-C | SSE-S3 (AES-256) |
| Versioning | Yes | Yes |
| Object lock | Yes | Yes (limited) |
| DynamoDB for locking | Native integration | Not available |
| Cross-region replication | Yes | Manual only |

## Questions Addressed

### 1. Does OVH Object Storage support state locking?

**No.** OVH Object Storage does not provide DynamoDB-equivalent locking. The S3 backend's `dynamodb_table` option requires AWS DynamoDB.

**Mitigations:**
- **Process-based locking**: Single operator workflow (acceptable for showcase project)
- **CI/CD locking**: Future option via Atlantis, Spacelift, or similar
- **Object lock (WORM)**: Not true locking but prevents accidental overwrites

**Risk assessment:**
- Solo operator: LOW risk (self-coordination)
- Small team (2-3): MEDIUM risk (use communication protocols)
- Larger team: HIGH risk (implement CI/CD-based locking)

### 2. Should we use server-side encryption?

**Yes.** OVH Object Storage supports SSE-S3 (AES-256 encryption).

Configuration:
```hcl
# Enable via bucket policy in OVH Control Panel
# Or set default encryption on PUT operations
```

The Terraform state contains sensitive data:
- Talos secrets and kubeconfig data
- API endpoints and credentials
- Machine configurations

Encryption at rest is essential. OVH handles key management.

### 3. What access credential approach?

**Recommendation:** Use OVH S3 credentials with environment variables.

| Option | Security | Convenience | Recommended |
|--------|----------|-------------|-------------|
| Credentials in backend.tfvars | LOW | HIGH | No |
| Environment variables | MEDIUM | MEDIUM | Yes |
| IAM role (AWS only) | HIGH | HIGH | N/A on OVH |
| CI/CD secrets | HIGH | MEDIUM | Future |

**Implementation:**
```bash
# Set in shell profile or CI/CD secrets
export AWS_ACCESS_KEY_ID="<ovh-s3-access-key>"
export AWS_SECRET_ACCESS_KEY="<ovh-s3-secret-key>"
```

**Credential scope:** Create dedicated S3 credentials for Terraform only. Do not reuse credentials with broader OVH API access.

### 4. How to handle state migration safely?

See "Migration Procedure" section below. Key principles:
- Multiple backups before migration
- Verify state integrity post-migration
- Keep local backup until remote is proven

### 5. What is the cost consideration?

**Minimal to zero additional cost.**

OVH Object Storage pricing (GRA region, as of 2026):
- Storage: ~0.01 EUR/GB/month
- Requests: ~0.01 EUR/10,000 requests
- Data transfer: Free within OVH network

For a 200KB state file with typical operations:
- Monthly storage: < 0.01 EUR
- Monthly requests: < 0.10 EUR (assuming ~1000 operations)

**Verdict:** Cost is negligible and should not factor into the decision.

## Decision

Proceed with migration using the following approach:

1. **Encryption:** Enable SSE-S3 on the bucket
2. **Versioning:** Enable bucket versioning for state history
3. **Credentials:** Environment variables (never in tfvars)
4. **Locking:** Accept no-locking limitation with documented process controls
5. **Backup:** Maintain local backup for 30 days post-migration

## Migration Procedure

### Pre-Migration Checklist

```
[ ] Verify current state is valid: tofu validate
[ ] Plan shows no changes: tofu plan
[ ] Create local backup: cp terraform.tfstate terraform.tfstate.pre-migration
[ ] Store backup in separate location (e.g., password manager, encrypted drive)
[ ] Document current state serial number for verification
```

### Phase 1: Create OVH Object Storage Bucket

1. **Create container via OVH Control Panel:**
   - Navigate to: Public Cloud > Object Storage > Create Container
   - Region: GRA (Gravelines) - same region as infrastructure
   - Container type: Standard (S3-compatible)
   - Name: `my-terraform-state`

2. **Enable versioning:**
   ```bash
   # Using AWS CLI with OVH endpoint
   aws s3api put-bucket-versioning \
     --bucket my-terraform-state \
     --versioning-configuration Status=Enabled \
     --endpoint-url https://s3.gra.io.cloud.ovh.net
   ```

3. **Enable server-side encryption (optional but recommended):**
   ```bash
   aws s3api put-bucket-encryption \
     --bucket my-terraform-state \
     --server-side-encryption-configuration '{
       "Rules": [{
         "ApplyServerSideEncryptionByDefault": {
           "SSEAlgorithm": "AES256"
         }
       }]
     }' \
     --endpoint-url https://s3.gra.io.cloud.ovh.net
   ```

### Phase 2: Generate and Configure Credentials

1. **Generate S3 credentials:**
   - OVH Control Panel > Users & Roles > Your User > Generate S3 Credentials
   - Note: These are separate from OVH API credentials

2. **Configure environment:**
   ```bash
   # Add to ~/.bashrc or ~/.zshrc (or use direnv)
   export AWS_ACCESS_KEY_ID="<your-access-key>"
   export AWS_SECRET_ACCESS_KEY="<your-secret-key>"
   ```

3. **Verify connectivity:**
   ```bash
   aws s3 ls --endpoint-url https://s3.gra.io.cloud.ovh.net
   ```

### Phase 3: Enable Backend Configuration

1. **Uncomment and update backend.tf:**
   ```hcl
   terraform {
     backend "s3" {
       bucket = "my-terraform-state"
       key    = "talos-cluster/terraform.tfstate"
       region = "gra"

       endpoints = {
         s3 = "https://s3.gra.io.cloud.ovh.net"
       }

       skip_credentials_validation = true
       skip_region_validation      = true
       skip_metadata_api_check     = true
       skip_requesting_account_id  = true
       skip_s3_checksum            = true
       use_path_style              = true
     }
   }
   ```

2. **Initialize with migration:**
   ```bash
   tofu init -migrate-state
   ```

   Expected output:
   ```
   Initializing the backend...
   Do you want to copy existing state to the new backend?
   ...
   Enter a value: yes

   Successfully configured the backend "s3"!
   ```

### Phase 4: Verification

1. **Verify remote state:**
   ```bash
   # List objects in bucket
   aws s3 ls s3://my-terraform-state/talos-cluster/ \
     --endpoint-url https://s3.gra.io.cloud.ovh.net
   ```

2. **Verify state content:**
   ```bash
   tofu state list
   ```

3. **Run plan to confirm no drift:**
   ```bash
   tofu plan
   # Should show: No changes. Your infrastructure matches the configuration.
   ```

4. **Verify versioning works:**
   ```bash
   aws s3api list-object-versions \
     --bucket my-terraform-state \
     --prefix talos-cluster/terraform.tfstate \
     --endpoint-url https://s3.gra.io.cloud.ovh.net
   ```

### Phase 5: Cleanup

1. **After successful verification (wait at least one successful apply cycle):**
   - Keep `terraform.tfstate.pre-migration` for 30 days
   - Remove old backup files: `rm terraform.tfstate.*.backup`

2. **Update documentation:**
   - Mark ADR-0010 as Accepted
   - Update README with new workflow

## Rollback Procedure

If migration fails or remote state becomes corrupted:

### Immediate Rollback (before any remote changes)

```bash
# 1. Comment out backend block in backend.tf
# 2. Re-initialize with local backend
tofu init -migrate-state
# Answer "yes" to copy state back to local

# 3. Verify
tofu plan
```

### Recovery from Backup

```bash
# 1. Comment out backend block
# 2. Restore pre-migration backup
cp terraform.tfstate.pre-migration terraform.tfstate

# 3. Re-initialize
tofu init

# 4. Verify state matches reality
tofu plan
```

### Recovery from Remote Version

```bash
# List versions
aws s3api list-object-versions \
  --bucket my-terraform-state \
  --prefix talos-cluster/terraform.tfstate \
  --endpoint-url https://s3.gra.io.cloud.ovh.net

# Download specific version
aws s3api get-object \
  --bucket my-terraform-state \
  --key talos-cluster/terraform.tfstate \
  --version-id <version-id> \
  terraform.tfstate.recovered \
  --endpoint-url https://s3.gra.io.cloud.ovh.net
```

## Consequences

### Positive

- State survives local machine failure
- Version history provides audit trail and recovery options
- Ready for team collaboration
- Consistent with ADR-0006 strategic decision
- Minimal/zero additional cost

### Negative

- No native state locking (process mitigation required)
- Additional infrastructure dependency (OVH Object Storage)
- Requires network connectivity for all Terraform operations

### Operational Impact

| Operation | Before | After |
|-----------|--------|-------|
| `tofu plan` | Local only | Requires network + OVH availability |
| `tofu apply` | Local only | Requires network + OVH availability |
| Concurrent operations | No protection | No protection (document this) |
| State recovery | Local backups only | Bucket versioning + local backup |
| Credential management | None | S3 credentials required |

## Process Controls (Locking Mitigation)

Since OVH Object Storage does not support native locking, implement these process controls:

1. **Communication Protocol:**
   - Before running `tofu apply`, announce in team channel
   - Use a shared flag (e.g., Slack status, shared doc) for "Terraform in progress"

2. **CI/CD Serialization (Future):**
   - Consider Atlantis or similar for PR-based applies
   - Single queue ensures serialized operations

3. **Lock File Convention:**
   - Optionally upload a `.lock` file before operations
   - Not enforced, but provides visibility:
   ```bash
   echo "$(whoami)@$(date)" | aws s3 cp - \
     s3://my-terraform-state/talos-cluster/.lock \
     --endpoint-url https://s3.gra.io.cloud.ovh.net
   ```

## Related Decisions

- ADR-0006: Remote State Backend (strategic decision)
- ADR-0005: Remote Access (Tailscale impacts how Terraform reaches the cluster)

## References

- [OVH Object Storage Documentation](https://docs.ovh.com/gb/en/storage/object-storage/)
- [OVH S3 Credentials Generation](https://docs.ovh.com/gb/en/storage/object-storage/s3/identity-and-access-management/)
- [OpenTofu S3 Backend Configuration](https://opentofu.org/docs/language/settings/backends/s3/)
- [Terraform State Locking Discussion](https://developer.hashicorp.com/terraform/language/state/locking)
