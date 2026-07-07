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

- **Firewall disabled by default** — intentional for bootstrapping: enabling the firewall before Tailscale connectivity is verified would lock the operator out, since with the firewall active the APIs are reachable via Tailscale only (recovery then requires iKVM console or rescue mode). After deployment, verify Tailscale access works (kubectl/talosctl against the ts.net endpoint), set `enable_firewall = true` and re-apply, then confirm with `tofu output firewall_verification_commands`. The staged activation flow is documented in `terraform.tfvars.example`. When the firewall is disabled, a `firewall_warning` output is displayed on every `tofu apply`.
- **ArgoCD initial admin password in state** — ArgoCD generates an initial admin password stored as a Kubernetes secret. This value is read into Terraform state for convenience. Rotate the password immediately after first login:
  1. `argocd account update-password`
  2. `kubectl delete secret argocd-initial-admin-secret -n argocd`
  3. Set `argocd_disable_admin = true` in `terraform.tfvars` and re-apply to disable the built-in admin account
- **Cilium install image** — uses a CI image tag with cluster-admin RBAC ([#11](https://github.com/xd-ventures/tf-xd-venture-talos01/issues/11))
- **Tailscale auth key transits OVH and remote state** — the pre-authorized key is embedded in the machine config, passes through the OVH reinstall API (held in their task/config-drive infrastructure), and persists in the remote state. Accepted residual risk: the key is single-use (`TS_AUTH_ONCE=true`), tag-scoped, expires after 1 hour, and the state bucket is encrypted and access-controlled (ADR-0006/ADR-0010).
- **Infrastructure identifiers in public CI output** — `tofu plan`/drift diffs on this public repository can render the tailnet name when identifier-carrying attributes change (e.g. the reinstall trigger list; [#282](https://github.com/xd-ventures/tf-xd-venture-talos01/issues/282)). Accepted: knowing the tailnet name grants no access (zero-trust device authorization), steady-state runs print no diff, and the trigger values will be replaced with hashes at the next planned reinstall (see the note in `main.tf`).
- **Shodan monitoring is IPv4-only** — the alert watches the public IPv4 `/32`; the server's routed IPv6 block is not monitored (free-tier IP limits make `/64` monitoring impractical) and the CI security suite also scans IPv4 only. IPv6 exposure protection relies on the Talos firewall rules themselves (which cover IPv6 via `tailscale_ipv6_cidr`).

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
