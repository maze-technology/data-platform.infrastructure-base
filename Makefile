.PHONY: help format validate plan apply destroy
.PHONY: localstack-up localstack-down localstack-status localstack-loki-bucket
.PHONY: kind-up kind-down kind-status
.PHONY: local-setup local-teardown

# Variables
CLUSTER_NAME ?= local
ENV ?= local
COMPOSE_FILE ?= docker-compose.yml
KIND_CONFIG ?= config/kind-config.yaml
BUCKET_NAME ?= loki-logs-local
LOCALSTACK_ENDPOINT ?= http://localhost:4566

# Detect docker compose command (v2 or v1)
DOCKER_COMPOSE := $(shell command -v docker compose >/dev/null 2>&1 && echo "docker compose" || echo "docker-compose")

# Default target
help: ## Show this help message
	@echo "Available targets:"
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | sort | awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-20s\033[0m %s\n", $$1, $$2}'

# Terraform/OpenTofu targets
format: ## Format all Terraform files
	@tofu fmt -recursive

validate: ## Validate Terraform configuration
	@cd iac/envs/$(ENV) && tofu validate

plan: ## Plan Terraform changes
	@cd iac/envs/$(ENV) && tofu plan

apply: ## Apply Terraform changes
	@cd iac/envs/$(ENV) && tofu apply

destroy: ## Destroy Terraform infrastructure
	@cd iac/envs/$(ENV) && tofu destroy

init: ## Initialize Terraform
	@cd iac/envs/$(ENV) && tofu init

# LocalStack targets
localstack-up: ## Start LocalStack
	@echo "Starting LocalStack..."
	@$(DOCKER_COMPOSE) -f $(COMPOSE_FILE) up -d
	@echo "Waiting for LocalStack to be ready..."
	@timeout=60; \
	while [ $$timeout -gt 0 ]; do \
		if curl -s $(LOCALSTACK_ENDPOINT)/_localstack/health | grep -q '"s3": "available"'; then \
			echo "✓ LocalStack is ready!"; \
			break; \
		fi; \
		timeout=$$((timeout - 2)); \
		sleep 2; \
	done; \
	if [ $$timeout -le 0 ]; then \
		echo "Error: LocalStack did not become ready in time"; \
		exit 1; \
	fi
	@$(MAKE) localstack-loki-bucket

localstack-down: ## Stop LocalStack
	@echo "Stopping LocalStack..."
	@$(DOCKER_COMPOSE) -f $(COMPOSE_FILE) down
	@echo "✓ LocalStack stopped"

localstack-status: ## Check LocalStack status
	@curl -s $(LOCALSTACK_ENDPOINT)/_localstack/health | jq '.' || echo "LocalStack is not running"

localstack-loki-bucket: ## Create S3 bucket for Loki in LocalStack
	@if command -v aws >/dev/null 2>&1; then \
		echo "Creating S3 bucket: $(BUCKET_NAME)"; \
		AWS_ACCESS_KEY_ID=test AWS_SECRET_ACCESS_KEY=test AWS_DEFAULT_REGION=us-east-1 \
		aws --endpoint-url=$(LOCALSTACK_ENDPOINT) s3 mb s3://$(BUCKET_NAME) 2>/dev/null || \
		echo "Bucket might already exist"; \
		echo "✓ Bucket '$(BUCKET_NAME)' is ready"; \
	else \
		echo "AWS CLI not found. Install it to create buckets automatically."; \
		echo "Or create manually: aws --endpoint-url=$(LOCALSTACK_ENDPOINT) s3 mb s3://$(BUCKET_NAME)"; \
	fi

# Kind cluster targets
kind-up: ## Create kind cluster
	@if ! command -v kind >/dev/null 2>&1; then \
		echo "Error: kind is not installed. Install from: https://kind.sigs.k8s.io/docs/user/quick-start/#installation"; \
		exit 1; \
	fi
	@if kind get clusters | grep -q "^$(CLUSTER_NAME)$$"; then \
		echo "Cluster $(CLUSTER_NAME) already exists. Use 'make kind-down' to remove it first."; \
		exit 1; \
	fi
	@echo "Creating kind cluster: $(CLUSTER_NAME)"
	@if [ -f $(KIND_CONFIG) ]; then \
		kind create cluster --name $(CLUSTER_NAME) --config $(KIND_CONFIG); \
	else \
		kind create cluster --name $(CLUSTER_NAME); \
	fi
	@kubectl cluster-info --context kind-$(CLUSTER_NAME)
	@if ! kubectl config current-context | grep -q "kind-$(CLUSTER_NAME)"; then \
		kubectl config use-context kind-$(CLUSTER_NAME); \
	fi
	@echo "✓ Kind cluster '$(CLUSTER_NAME)' created successfully!"
	@echo "✓ Current context: $$(kubectl config current-context)"

kind-down: ## Delete kind cluster
	@if ! command -v kind >/dev/null 2>&1; then \
		echo "Error: kind is not installed."; \
		exit 1; \
	fi
	@if ! kind get clusters | grep -q "^$(CLUSTER_NAME)$$"; then \
		echo "Cluster $(CLUSTER_NAME) does not exist."; \
		exit 1; \
	fi
	@echo "Deleting kind cluster: $(CLUSTER_NAME)"
	@kind delete cluster --name $(CLUSTER_NAME)
	@echo "✓ Kind cluster '$(CLUSTER_NAME)' deleted successfully!"

kind-status: ## Check kind cluster status
	@if kind get clusters | grep -q "^$(CLUSTER_NAME)$$"; then \
		echo "Cluster '$(CLUSTER_NAME)' is running"; \
		kubectl cluster-info --context kind-$(CLUSTER_NAME) 2>/dev/null || echo "Cluster exists but kubectl context not set"; \
	else \
		echo "Cluster '$(CLUSTER_NAME)' does not exist"; \
	fi

# Combined local development targets
local-setup: ## Set up complete local development environment (LocalStack + Kind)
	@echo "Setting up local development environment..."
	@$(MAKE) localstack-up
	@$(MAKE) kind-up
	@echo ""
	@echo "✓ Local development environment is ready!"
	@echo ""
	@echo "Next steps:"
	@echo "  1. cd iac/envs/local"
	@echo "  2. make init"
	@echo "  3. make plan"
	@echo "  4. make apply"

local-teardown: ## Tear down local development environment
	@echo "Tearing down local development environment..."
	@$(MAKE) kind-down
	@$(MAKE) localstack-down
	@echo "✓ Local development environment torn down"
