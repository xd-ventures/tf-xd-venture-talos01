# Secret Rotation Procedures

This document describes how to rotate each credential used by the project.

## Overview

| Credential | Rotation Method | Urgency on Compromise |
|------------|----------------|----------------------|
| OVH API credentials | Manual — create new token, update env vars | High — full server control |
| Tailscale OAuth client | Manual — create new client in admin console | High — tailnet access |
| Tailscale auth key | Automatic — single-use, expires in 1 hour | Low — transient |
| ArgoCD admin password | CLI — change password, delete initial secret | Medium — cluster GitOps |
| Talos PKI (machine secrets) | Destructive — requires cluster reinstall | Critical — cluster identity |

---

## OVH API Credentials

The OVH API uses three values: Application Key, Application Secret, and Consumer Key.

### When to Rotate

- Suspected compromise
- Personnel change (credentials are user-associated)
- Token expiry (consumer keys can have time-limited validity)

### Procedure

1. **Create a new application** at <https://api.ovh.com/createToken/> with the
   required API rights (see `TESTING_STRATEGY.md` for the minimum permission set).

2. **Update environment variables** wherever they are configured:
   ```bash
   export OVH_APPLICATION_KEY="new-app-key"
   export OVH_APPLICATION_SECRET="new-app-secret"
   export OVH_CONSUMER_KEY="new-consumer-key"
   ```

3. **Verify connectivity**:
   ```bash
   ./scripts/ovh-server-status.sh
   ```

4. **Revoke the old token** — OVH does not provide a self-service revocation UI.
   Contact OVH support or let the consumer key expire naturally.

> **Note**: The OVH provider in `versions.tf` reads credentials from environment
> variables via the `endpoint` configuration in `versions.tf`. No Terraform state
> changes are needed.

---

## Tailscale OAuth Client

The Tailscale provider uses an OAuth client for API access. OAuth credentials
do not expire (unlike API keys), so rotation is only needed on compromise or
policy change.

### When to Rotate

- Suspected compromise
- Scope change (adding/removing `devices:core`, `devices:read`)
- Personnel change

### Procedure

1. **Create a new OAuth client** in the Tailscale admin console at
   [Settings > OAuth clients](https://login.tailscale.com/admin/settings/oauth).
   - Required scopes: `auth_keys`
   - Recommended scopes: `devices:read`, `devices:core`
   - See [ADR-0008](adr/0008-tailscale-authentication-strategy.md) for scope details.

2. **Update environment variables**:
   ```bash
   export TAILSCALE_OAUTH_CLIENT_ID="new-client-id"
   export TAILSCALE_OAUTH_CLIENT_SECRET="tskey-client-xxx"
   ```

3. **Verify connectivity**:
   ```bash
   tofu plan   # Should succeed without auth errors
   ```

4. **Delete the old OAuth client** in the Tailscale admin console.

> **Note**: The Tailscale auth key generated for the cluster node is single-use
> and expires in 1 hour. It does not need manual rotation — a fresh key is
> generated automatically on each reinstall via `replace_triggered_by`.

---

## ArgoCD Admin Password

ArgoCD generates a random initial admin password stored in the
`argocd-initial-admin-secret` Kubernetes secret.

### When to Rotate

- After initial deployment (recommended)
- Suspected compromise
- Personnel change

### Procedure

1. **Get the current password**:
   ```bash
   tofu output -raw argocd_admin_password
   ```

2. **Port-forward to ArgoCD**:
   ```bash
   kubectl port-forward svc/argocd-server -n argocd 8080:443
   ```

3. **Change the password** using the ArgoCD CLI:
   ```bash
   argocd login localhost:8080 --insecure --username admin \
     --password "$(tofu output -raw argocd_admin_password)"

   argocd account update-password --account admin \
     --current-password "$(tofu output -raw argocd_admin_password)" \
     --new-password "<new-password>"
   ```

4. **Delete the initial admin secret** (prevents leaking the old password):
   ```bash
   kubectl delete secret argocd-initial-admin-secret -n argocd
   ```

5. **Optionally disable the admin account** — set `argocd_disable_admin = true`
   in `terraform.tfvars` and re-apply. Re-enable if you need to recover access.

> **Warning**: After deleting the initial secret and disabling the admin account,
> the only way to recover access is to re-enable the admin account in
> `terraform.tfvars` and re-apply, which recreates the initial secret.

---

## Talos PKI / Machine Secrets

Talos machine secrets contain the cluster's PKI (CA certificates, keys, bootstrap
token, etcd encryption key). These are generated once by `talos_machine_secrets.this`
and stored in Terraform state.

### When to Rotate

- Suspected compromise of the Terraform state file
- Suspected compromise of the cluster CA
- Compliance requirements

### Procedure

> **Warning**: Rotating Talos machine secrets is a **destructive operation**. It
> generates a new cluster CA, which requires a full reinstall. All workloads,
> etcd state, and ZFS pools will be lost.

1. **Back up persistent data** from ZFS pools.

2. **Taint the machine secrets** to force regeneration:
   ```bash
   tofu taint talos_machine_secrets.this
   ```

3. **Apply** — this triggers a full cluster reinstall with new PKI:
   ```bash
   tofu apply
   ```

4. **Re-export kubeconfig and talosconfig** (they contain new certificates):
   ```bash
   tofu output -raw kubeconfig > kubeconfig && chmod 600 kubeconfig
   tofu output -raw talosconfig > talosconfig && chmod 600 talosconfig
   ```

5. **Restore data** to the new ZFS pool.

---

## Terraform State Backend Credentials

The S3 backend (OVH Object Storage) uses AWS-compatible access keys.

### When to Rotate

- Suspected compromise
- Key expiry

### Procedure

1. **Create new S3 credentials** in the OVH Cloud Manager or via the OVH API.

2. **Update environment variables**:
   ```bash
   export AWS_ACCESS_KEY_ID="new-access-key"
   export AWS_SECRET_ACCESS_KEY="new-secret-key"
   ```

3. **Re-initialize** to verify backend access:
   ```bash
   tofu init -backend-config=backend.tfvars
   ```

4. **Revoke the old credentials** in the OVH Cloud Manager.

---

## Related Documents

- [ADR-0008: Tailscale Authentication](adr/0008-tailscale-authentication-strategy.md) — OAuth client scopes
- [ADR-0006: Remote State Backend](adr/0006-remote-state-backend.md) — state backend setup
- [Operations Runbook](OPERATIONS_RUNBOOK.md) — day-to-day operational procedures
