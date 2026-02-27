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

## PR Review Comment Policy

Every comment on a PR (from bots, reviewers, or maintainers) **must** receive a reply describing the action taken. No comment should go unanswered.

### Required Actions

For each comment, choose exactly one response:

1. **Fix immediately** — The concern is valid and within scope. Push a fix commit to the PR branch and reply with a reference to the commit that addresses it.
2. **Explain why it's invalid** — The concern is based on a misunderstanding or incorrect assumption. Reply with a clear explanation of why no change is needed.
3. **Acknowledge and defer** — The concern is valid but out of scope for this PR. Reply explaining this, create a new GitHub issue immediately, and reference the issue number in the reply.

### Rules

- Act on the chosen response **immediately** — do not leave comments pending
- When deferring, the new issue must be created before replying to the comment
- When fixing, the fix commit must be pushed before replying to the comment
- Use `gh api` to reply to PR review comments programmatically:
  ```bash
  # Reply to a review comment
  gh api repos/{owner}/{repo}/pulls/{pr}/comments/{comment_id}/replies \
    -f body="Fixed in <commit>. <explanation>"
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

### Naming Conventions

All identifiers use `snake_case`. The existing codebase follows these patterns — apply them to new resources.

#### Resource & Data Source Names

| Pattern | When | Examples |
|---------|------|---------|
| `this` | Singleton resources (only one instance ever) | `talos_machine_secrets.this`, `talos_machine_bootstrap.this` |
| Descriptive | Resource has a distinguishing role/purpose | `ovh_dedicated_server.talos01`, `talos_machine_configuration.controlplane`, `shodan_alert.server` |

#### Variables

- Prefix with feature/component: `tailscale_*`, `argocd_*`, `zfs_pool_*`, `shodan_*`
- Boolean flags: `{thing}_enabled` (e.g., `argocd_enabled`, `enable_firewall`)
- Network: `{network}_cidr`, `{network}_ip`

#### Locals

- Group by function with comments: endpoints, config patches (`*_config_patch`), manifests (`*_manifest`), boolean flags
- Derived locals may mirror a variable for readability (e.g., `argocd_enabled = var.argocd_enabled`)

#### Outputs

- Group by component with comment headers
- Informational: `{component}_info` or `{component}_access_info`
- Status/flags: `{component}_enabled`, `{component}_status`
- Commands: `*_command`, `*_save_command`
- Tool configs: match tool names exactly (`talosconfig`, `kubeconfig` — not `talos_config`)
- Conditional outputs: both branches must have matching object keys (use `null` for disabled state)

## iKVM Console Debugging (MCP)

When a server is unreachable over the network, use [ovh-ikvm-mcp](https://github.com/xd-ventures/ovh-ikvm-mcp) to capture console screenshots via iKVM/IPMI. This project's `.mcp.json` auto-registers it.

### Start the server

```bash
# Docker (recommended)
docker run --rm -e OVH_ENDPOINT=eu -e OVH_APPLICATION_KEY=... -e OVH_APPLICATION_SECRET=... -e OVH_CONSUMER_KEY=... -p 3001:3001 ghcr.io/xd-ventures/ovh-ikvm-mcp:latest

# Or local Bun
cd ~/ovh-ikvm-mcp
export OVH_ENDPOINT="eu" OVH_APPLICATION_KEY="..." OVH_APPLICATION_SECRET="..." OVH_CONSUMER_KEY="..."
bun start   # listens on http://localhost:3001/mcp
```

### MCP tools

- `list_servers` — list bare metal servers with their IDs
- `get_screenshot(serverId)` — capture a PNG screenshot of the server console (optimized for LLM vision)

### When to use

Use this when the server is stuck during boot, shows a kernel panic, has networking issues, or is otherwise unreachable. Take a screenshot, read the console output, and diagnose the problem.

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
# Pre-commit
pre-commit install          # First-time setup
pre-commit run --all-files  # Run all checks

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
