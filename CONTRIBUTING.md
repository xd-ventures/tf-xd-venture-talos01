# Contributing

Contributions are welcome! This is a solo hobby project, so PR reviews may take some time. Your patience is appreciated.

## Getting Started

### Prerequisites

- [OpenTofu](https://opentofu.org/) >= 1.6.0
- [pre-commit](https://pre-commit.com/)
- [TFLint](https://github.com/terraform-linters/tflint)

### First-Time Setup

```bash
# Install pre-commit hooks (runs automatically on every commit)
pip install pre-commit
pre-commit install

# Initialize OpenTofu providers
tofu init
```

## Development Workflow

This project uses **GitHub Flow** with an issue-first approach.

### 1. Open an Issue

For features, bugs, and significant refactoring — [open an issue](https://github.com/xd-ventures/tf-xd-venture-talos01/issues/new/choose) first. This allows discussion before implementation. Minor fixes (typos, small doc updates) can skip this step.

### 2. Create a Branch

Include the issue number when applicable:

```
feature/<issue>-<description>    # e.g., feature/42-add-ingress
fix/<issue>-<description>        # e.g., fix/15-tailscale-timeout
docs/<description>
refactor/<description>
chore/<description>
```

### 3. Make Changes

Follow the commit format:

```
<type>: <short summary in imperative mood>

[optional body explaining WHY]
```

Types: `feat:`, `fix:`, `docs:`, `refactor:`, `chore:`, `test:`

### 4. Run Checks Locally

```bash
pre-commit run --all-files
```

This runs all the same checks as CI: OpenTofu formatting, validation, TFLint, ShellCheck, secret scanning, and more.

### 5. Open a Pull Request

- Reference the issue in the PR body (e.g., `Fixes #42`)
- CI runs pre-commit hooks and a Trivy security scan
- CRITICAL severity findings or secret leaks will fail the build

## For AI Agents

See [AGENTS.md](AGENTS.md) for detailed workflow instructions and [CLAUDE.md](CLAUDE.md) for Claude Code-specific guidance.

## Code of Conduct

This project follows the [Contributor Covenant](CODE_OF_CONDUCT.md). Please read it before participating.
