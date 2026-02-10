# Security Policy

We take the security of this project seriously and appreciate responsible disclosure of vulnerabilities.

## Supported Versions

Only the latest commit on the `main` branch is supported. There are no backported security fixes to older commits or tags.

## Security Model

This project deploys a Talos Kubernetes cluster with a defense-in-depth approach:

- **Talos mTLS** — all API access requires mutual TLS certificates
- **Tailscale zero-trust** — admin access restricted to Tailscale VPN mesh
- **Host firewall** — Talos NetworkRuleConfig blocks public IP access (when enabled)

The default configuration is intentionally **open for bootstrapping** (`enable_firewall = false`). The expected workflow is: deploy, verify Tailscale connectivity, then enable the firewall. See `terraform.tfvars.example` for the hardening steps.

## Scope

### In Scope

Report these as security vulnerabilities:

- **Secrets or credentials in tracked files** — hardcoded API keys, tokens, or private keys in `.tf` files, scripts, or other committed files (including git history)
- **Insecure defaults** — default configurations that weaken security beyond what is documented as an intentional bootstrapping trade-off
- **Code injection** — shell injection, path traversal, or command injection in scripts or provisioners
- **Overly permissive RBAC or IAM** — Terraform resources or Kubernetes configurations granting broader permissions than necessary
- **Supply chain risks** — mutable container image tags, unsigned providers, or unverified Helm charts in default-enabled components
- **Information disclosure** — outputs, state, or logs that inadvertently expose sensitive data
- **Insecure patterns in documentation** — instructions or examples that lead users toward insecure configurations

### Out of Scope

These should be reported to the respective upstream projects:

- **Talos Linux vulnerabilities** — report to [SideroLabs](https://github.com/siderolabs/talos/security)
- **Cilium vulnerabilities** — report to [Cilium](https://github.com/cilium/cilium/security)
- **Tailscale vulnerabilities** — report to [Tailscale](https://tailscale.com/security)
- **ArgoCD vulnerabilities** — report to [Argo Project](https://github.com/argoproj/argo-cd/security)
- **OVH platform security** — contact [OVHcloud](https://www.ovhcloud.com/en/security/)
- **Kubernetes core vulnerabilities** — report to [Kubernetes](https://kubernetes.io/docs/reference/issues-security/security/)
- **OpenTofu/Terraform core vulnerabilities** — report to the respective projects

Also out of scope:

- User-deployed workloads after cluster provisioning
- Operator decisions to deviate from documented security configuration (e.g., leaving the firewall disabled in production)
- Denial of service against the deployed cluster (this project is IaC, not a running service)

## Known Security Considerations

The following are known and tracked. You do not need to report these:

- **Firewall disabled by default** — intentional for bootstrapping; hardening steps documented in `terraform.tfvars.example`
- **Cilium install image** — uses a CI image tag with cluster-admin RBAC ([#11](https://github.com/xd-ventures/tf-xd-venture-talos01/issues/11))
- **ArgoCD/firewall hardening** — additional hardening opportunities tracked in [#19](https://github.com/xd-ventures/tf-xd-venture-talos01/issues/19)

Security-relevant issues are labeled [`security`](https://github.com/xd-ventures/tf-xd-venture-talos01/labels/security) in the issue tracker.

## Credential Management

This project requires the following credentials, which must **never** be committed to the repository:

| Credential | Purpose | Storage |
|---|---|---|
| OVH API key/secret/consumer key | Server provisioning | Environment variables |
| Tailscale OAuth client ID/secret | VPN authentication | Environment variables |
| S3 backend credentials | Remote state | `backend.tfvars` (gitignored) |

The Terraform state file (`terraform.tfstate`) contains cluster PKI material, kubeconfig, and other sensitive data. Treat state with the same care as root credentials. Use an encrypted backend with access controls.

## Reporting a Vulnerability

**Please do not open public GitHub issues for security vulnerabilities.**

Use [GitHub Private Vulnerability Reporting](https://github.com/xd-ventures/tf-xd-venture-talos01/security/advisories/new) to submit reports. This keeps the discussion private until a fix is available.

### What to Include

- Description of the vulnerability
- Steps to reproduce
- Affected files or configurations
- Potential impact
- Suggested fix (if you have one)

### Response Timeline

This is a solo hobby project. Response times reflect that honestly:

- **Acknowledgment**: within 7 days
- **Initial assessment**: within 14 days
- **Fix target**: within 90 days for confirmed vulnerabilities (critical issues like exposed secrets will be addressed faster)

If you do not receive an acknowledgment within 14 days, please follow up on the same advisory thread.

## Safe Harbor

We will not pursue legal action against security researchers who:

- Act in good faith according to this policy
- Do not access, modify, or delete data beyond what is necessary to demonstrate the vulnerability
- Report findings promptly and allow reasonable time for remediation before public disclosure

We will credit reporters in the advisory unless they prefer to remain anonymous.
