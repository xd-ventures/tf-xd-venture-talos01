# SPDX-License-Identifier: Apache-2.0
# Copyright Maciej Sawicki

.PHONY: init validate plan apply deploy test test-smoke test-config test-storage test-security fmt lint setup kubeconfig talosconfig status clean help

# The consumer root lives in infra/ after the module extraction (ADR-0016);
# tofu runs there via -chdir so make targets still work from the repo root.
TOFU_DIR := infra

help: ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-15s\033[0m %s\n", $$1, $$2}'

init: ## Initialize OpenTofu providers and backend
	tofu -chdir=$(TOFU_DIR) init

validate: ## Validate configuration and run linter
	tofu -chdir=$(TOFU_DIR) validate
	tflint --chdir=$(TOFU_DIR)

plan: ## Show execution plan
	tofu -chdir=$(TOFU_DIR) plan

apply: ## Apply infrastructure changes
	tofu -chdir=$(TOFU_DIR) apply

# Single recipe (not prerequisites): prerequisite ordering is not guaranteed
# under `make -j`, and each step depends on the previous one's side effects.
deploy: ## Apply and run validation checks
	$(MAKE) apply
	$(MAKE) kubeconfig
	$(MAKE) talosconfig
	$(MAKE) test

test: ## Run all cluster validation checks (TAP output)
	python3 scripts/cluster_checks.py --suite all

test-smoke: ## Run smoke tests (Talos API reachability)
	python3 scripts/cluster_checks.py --suite smoke

test-config: ## Run config validation (extensions, manifests, pods)
	python3 scripts/cluster_checks.py --suite config

test-storage: ## Run storage checks (ZFS pool, PV write)
	python3 scripts/cluster_checks.py --suite storage

test-security: ## Run security checks (firewall port scan)
	python3 scripts/cluster_checks.py --suite security

fmt: ## Format all OpenTofu files
	tofu fmt -recursive

lint: ## Run all pre-commit hooks
	pre-commit run --all-files

setup: ## First-time setup: install pre-commit hooks
	pip install pre-commit
	pre-commit install

# umask + tmp/mv: never leave a truncated or world-readable credentials file
# behind when `tofu output` fails mid-write (#245).
kubeconfig: ## Export kubeconfig from cluster
	umask 077 && tofu -chdir=$(TOFU_DIR) output -raw kubeconfig > kubeconfig.tmp && mv kubeconfig.tmp kubeconfig
	@echo "Run: export KUBECONFIG=$$PWD/kubeconfig"

talosconfig: ## Export talosconfig from cluster
	umask 077 && tofu -chdir=$(TOFU_DIR) output -raw talosconfig > talosconfig.tmp && mv talosconfig.tmp talosconfig
	@echo "Run: export TALOSCONFIG=$$PWD/talosconfig"

status: ## Check OVH server status
	./scripts/ovh-server-status.sh

clean: ## Remove local state and cache (use with caution)
	rm -rf $(TOFU_DIR)/.terraform/
	rm -f $(TOFU_DIR)/.terraform.lock.hcl
