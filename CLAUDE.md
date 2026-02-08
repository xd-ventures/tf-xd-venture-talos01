# CLAUDE.md - Claude Code Instructions

> Talos Kubernetes cluster on OVH bare metal with Tailscale VPN access

## Project Overview

This is an OpenTofu project deploying a production-ready Talos Kubernetes cluster on OVH dedicated servers. Key components:
- **OS**: Talos Linux (immutable, API-managed)
- **CNI**: Cilium with eBPF dataplane and Hubble observability
- **Access**: Tailscale VPN (zero-trust, no public IP exposure)
- **Storage**: ZFS mirror across NVMe drives
- **GitOps**: ArgoCD for application deployment

## Tech Stack & Tools

- **IaC**: OpenTofu (prefer over Terraform)
- **Scripting**: Python over Bash for complex logic
- **Style**: Declarative over imperative
- **Validation**: Always run `tofu validate` and `tflint` before commits

## GitHub CLI Commands

Use `gh` CLI for all GitHub operations:

```bash
# Issues
gh issue list                              # List open issues
gh issue list --search "keyword"           # Search issues
gh issue create --title "..." --body "..." # Create new issue
gh issue view <number>                     # View issue details

# Pull Requests
gh pr create --title "..." --body "..."    # Create PR
gh pr list                                  # List open PRs
gh pr view <number>                         # View PR details
gh pr checkout <number>                     # Checkout PR locally
```

## Git Workflow: GitHub Flow

The `main` branch is always deployable. All work happens on feature branches merged via PRs.

### Branch Naming

Include issue number when applicable:
- `feature/<issue>-<description>` (e.g., `feature/42-add-ingress`)
- `fix/<issue>-<description>` (e.g., `fix/15-tailscale-timeout`)
- `docs/<description>`, `refactor/<description>`, `chore/<description>`

### Commit Format

```
<type>: <short summary in imperative mood>

[optional body explaining WHY]

[optional footer with refs]
```

Types: `feat:`, `fix:`, `docs:`, `refactor:`, `chore:`, `test:`

### Creating PRs

When a PR addresses an issue, use `Fixes #<number>` in the body:

```bash
gh pr create --title "feat: add monitoring" --body "$(cat <<'EOF'
## Summary
Brief description of changes.

## Related Issue
Fixes #42

## Changes
- Key change 1
- Key change 2

## Testing
- [x] `tofu validate` passes
- [x] `tflint` passes
EOF
)"
```

## Issue-First Workflow

Create issues for: features, bugs, significant refactoring, breaking changes.

Skip issues for: typos, minor doc updates, small cosmetic changes.

```bash
# Find existing issues first
gh issue list --search "keyword"

# Create if none exists
gh issue create --title "feat: add dashboard" --body "Description..."

# Reference in branch name
git checkout -b feature/42-add-dashboard
```

## Code Quality Checklist

Before creating a PR:
- [ ] `tofu validate` passes
- [ ] `tflint` passes (static analysis)
- [ ] Commits follow format (`feat:`, `fix:`, etc.)
- [ ] Branch includes issue number if applicable
- [ ] PR description includes `Fixes #<number>` if addressing an issue

## Technical Guidelines

### Bash Scripts
- Enable strict mode: `set -euo pipefail`
- Quote variables, validate inputs
- Use ShellCheck compliance
- Prefer Python for scripts >300 lines

### Security
- Apply principle of least privilege
- Consider secrets management
- Document security assumptions

## Key Files

```
main.tf          # OVH server + reinstall task
talos.tf         # Talos configuration and bootstrap
tailscale.tf     # Tailscale provider and auth key
firewall.tf      # Network firewall rules
argocd.tf        # ArgoCD deployment
variables.tf     # Input variables
outputs.tf       # Output values
```

## Quick Commands

```bash
# Initialize
tofu init

# Validate
tofu validate && tflint

# Plan and apply
tofu plan
tofu apply

# Get kubeconfig
tofu output -raw kubeconfig > kubeconfig
export KUBECONFIG=$PWD/kubeconfig

# Get talosconfig
tofu output -raw talosconfig > talosconfig
export TALOSCONFIG=$PWD/talosconfig
```
