.PHONY: init validate plan apply deploy test test-smoke test-config test-storage test-security fmt lint setup kubeconfig talosconfig status clean help

help: ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-15s\033[0m %s\n", $$1, $$2}'

init: ## Initialize OpenTofu providers and backend
	tofu init

validate: ## Validate configuration and run linter
	tofu validate
	tflint

plan: ## Show execution plan
	tofu plan

apply: ## Apply infrastructure changes
	tofu apply

deploy: apply kubeconfig talosconfig test ## Apply and run validation checks

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

kubeconfig: ## Export kubeconfig from cluster
	tofu output -raw kubeconfig > kubeconfig
	chmod 600 kubeconfig
	@echo "Run: export KUBECONFIG=$$PWD/kubeconfig"

talosconfig: ## Export talosconfig from cluster
	tofu output -raw talosconfig > talosconfig
	chmod 600 talosconfig
	@echo "Run: export TALOSCONFIG=$$PWD/talosconfig"

status: ## Check OVH server status
	./scripts/ovh-server-status.sh

clean: ## Remove local state and cache (use with caution)
	rm -rf .terraform/
	rm -f .terraform.lock.hcl
