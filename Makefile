.PHONY: help format validate plan apply destroy
.PHONY: kind-up kind-down kind-status
.PHONY: local-setup local-teardown
.PHONY: ensure-rook-crds
.PHONY: prepull-ceph-image

# Variables
CLUSTER_NAME ?= local
ENV ?= local
KIND_CONFIG ?= config/kind-config.yaml

# Default target
help: ## Show this help message
	@echo "Available targets:"
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | sort | awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-20s\033[0m %s\n", $$1, $$2}'

# Terraform/OpenTofu targets
format: ## Format all Terraform files
	@tofu fmt -recursive

validate: ## Validate Terraform configuration
	@cd iac/envs/$(ENV) && tofu validate

ensure-rook-crds: ## Ensure Rook CRDs are installed (internal target)
	@cd iac/envs/$(ENV) && \
	if ! kubectl get crd cephclusters.ceph.rook.io >/dev/null 2>&1; then \
		echo "Rook CRDs not found. Terraform will detect and install them automatically."; \
		echo "This is required because kubernetes_manifest validates during plan/apply."; \
		tofu apply -target='module.rook_ceph.null_resource.install_and_verify_rook_crds' -auto-approve || { \
			echo "Error: CRD installation failed. Cannot proceed."; \
			exit 1; \
		}; \
	fi

plan: ensure-rook-crds ## Plan Terraform changes (automatically installs Rook CRDs if needed)
	@cd iac/envs/$(ENV) && tofu plan

# Two-stage apply process
apply-foundation: ensure-rook-crds ## Apply foundation layer (Rook-Ceph, Vault, RGW Bootstrap - stores credentials)
	@echo "=========================================="
	@echo "Foundation Layer: Storage + Secrets"
	@echo "=========================================="
	@echo "Step 1: Applying Rook-Ceph and Vault..."
	@cd iac/envs/$(ENV) && tofu apply \
		-target='module.rook_ceph' \
		-target='module.vault' \
		-auto-approve
	@echo ""
	@echo "Step 2: Waiting for Rook operator to be ready..."
	@echo "Checking operator pod status..."
	@OPERATOR_READY=0; \
	for i in $$(seq 1 30); do \
		if kubectl get pod -n rook-ceph -l app=rook-ceph-operator -o jsonpath='{.items[0].status.phase}' 2>/dev/null | grep -q "Running"; then \
			if kubectl get pod -n rook-ceph -l app=rook-ceph-operator -o jsonpath='{.items[0].status.containerStatuses[0].ready}' 2>/dev/null | grep -q "true"; then \
				echo "✓ Rook operator is ready!"; \
				OPERATOR_READY=1; \
				break; \
			fi; \
		fi; \
		if [ $$((i % 6)) -eq 0 ]; then \
			echo "[$$i/30] Waiting for operator... ($$(date +%H:%M:%S))"; \
			kubectl get pod -n rook-ceph -l app=rook-ceph-operator 2>/dev/null | tail -1 || echo "  Operator pod not found"; \
		fi; \
		sleep 5; \
	done; \
	if [ $$OPERATOR_READY -eq 0 ]; then \
		echo ""; \
		echo "❌ Error: Rook operator not ready after 2.5 minutes."; \
		echo ""; \
		echo "Diagnostics:"; \
		kubectl get pod -n rook-ceph -l app=rook-ceph-operator 2>/dev/null || echo "  Operator pod not found"; \
		echo ""; \
		echo "Troubleshooting:"; \
		echo "1. Check operator logs: kubectl logs -n rook-ceph -l app=rook-ceph-operator --tail=50"; \
		echo "2. Check operator events: kubectl describe pod -n rook-ceph -l app=rook-ceph-operator"; \
		exit 1; \
	fi
	@echo ""
	@echo "Step 3: Checking CephCluster status..."
	@echo "Note: CephCluster initialization can take 10+ minutes. We'll proceed to RGW setup."
	@echo "The RGW secret wait will naturally wait for the cluster to be ready."
	@CLUSTER_EXISTS=$$(kubectl get cephcluster -n rook-ceph 2>/dev/null | grep -q "rook-ceph" && echo "yes" || echo "no"); \
	if [ "$$CLUSTER_EXISTS" = "yes" ]; then \
		MON_PODS=$$(kubectl get pods -n rook-ceph -l app=rook-ceph-mon --field-selector=status.phase=Running --no-headers 2>/dev/null | wc -l | tr -d ' ' || echo "0"); \
		MGR_PODS=$$(kubectl get pods -n rook-ceph -l app=rook-ceph-mgr --field-selector=status.phase=Running --no-headers 2>/dev/null | wc -l | tr -d ' ' || echo "0"); \
		PHASE=$$(kubectl get cephcluster -n rook-ceph -o jsonpath='{.items[0].status.phase}' 2>/dev/null || echo ""); \
		echo "  CephCluster exists: yes"; \
		echo "  MON pods: $$MON_PODS, MGR pods: $$MGR_PODS"; \
		if [ -n "$$PHASE" ]; then \
			echo "  Phase: $$PHASE"; \
		fi; \
	else \
		echo "  CephCluster resource not found yet"; \
	fi; \
	echo "  Continuing to RGW setup (will wait for cluster readiness during secret creation)..."
	@echo ""
	@echo "Step 4: Waiting for CephObjectStore to be ready..."
	@STORE_NAME="rgw-store"; \
	STORE_READY=0; \
	for i in $$(seq 1 120); do \
		PHASE=$$(kubectl get cephobjectstore -n rook-ceph $$STORE_NAME -o jsonpath='{.status.phase}' 2>/dev/null || echo ""); \
		ENDPOINT=$$(kubectl get cephobjectstore -n rook-ceph $$STORE_NAME -o jsonpath='{.status.info.endpoint}' 2>/dev/null || echo ""); \
		if [ "$$PHASE" = "Ready" ]; then \
			echo "✓ CephObjectStore is ready!"; \
			STORE_READY=1; \
			break; \
		fi; \
		if [ -n "$$ENDPOINT" ] && [ "$$PHASE" = "Progressing" ]; then \
			echo "✓ CephObjectStore has endpoint ($$ENDPOINT), proceeding..."; \
			STORE_READY=1; \
			break; \
		fi; \
		if [ $$((i % 12)) -eq 0 ]; then \
			echo "[$$i/120] Waiting for CephObjectStore... ($$(date +%H:%M:%S))"; \
			echo "  Phase: $${PHASE:-<not set>}, Endpoint: $${ENDPOINT:-<not set>}"; \
		fi; \
		sleep 5; \
	done; \
	if [ $$STORE_READY -eq 0 ]; then \
		echo ""; \
		echo "⚠ Warning: CephObjectStore not ready after 10 minutes, but continuing..."; \
		echo "  Phase: $$(kubectl get cephobjectstore -n rook-ceph $$STORE_NAME -o jsonpath='{.status.phase}' 2>/dev/null || echo 'unknown')"; \
		echo "  Endpoint: $$(kubectl get cephobjectstore -n rook-ceph $$STORE_NAME -o jsonpath='{.status.info.endpoint}' 2>/dev/null || echo 'unknown')"; \
	fi
	@echo ""
	@echo "Step 5: Waiting for CephCluster to be ready (required for RGW secret creation)..."
	@echo "This may take 15+ minutes (large images need to be pulled)..."
	@CLUSTER_READY=0; \
	RETRY_COUNT=0; \
	for i in $$(seq 1 240); do \
		VERSION_JOB=$$(kubectl get job -n rook-ceph rook-ceph-detect-version -o jsonpath='{.status.conditions[?(@.type=="Complete")].status}' 2>/dev/null || echo ""); \
		VERSION_JOB_FAILED=$$(kubectl get job -n rook-ceph rook-ceph-detect-version -o jsonpath='{.status.conditions[?(@.type=="Failed")].status}' 2>/dev/null || echo ""); \
		VERSION_POD=$$(kubectl get pod -n rook-ceph -l job-name=rook-ceph-detect-version -o name 2>/dev/null | grep -v "Succeeded\|Failed" | head -1); \
		POD_STATUS=$$(kubectl get pod -n rook-ceph -l job-name=rook-ceph-detect-version -o jsonpath='{.items[0].status.containerStatuses[0].state.waiting.reason}' 2>/dev/null || echo ""); \
		if [ "$$VERSION_JOB_FAILED" = "True" ]; then \
			echo ""; \
			echo "⚠ Version detection job failed. Checking pod logs..."; \
			if [ -n "$$VERSION_POD" ]; then \
				kubectl logs -n rook-ceph $$VERSION_POD --tail=50 2>/dev/null || true; \
				kubectl describe -n rook-ceph $$VERSION_POD | tail -30 || true; \
			fi; \
			echo ""; \
			echo "Attempting to delete failed job to trigger retry..."; \
			kubectl delete job -n rook-ceph rook-ceph-detect-version 2>/dev/null || true; \
			sleep 5; \
		fi; \
		MON_PODS=$$(kubectl get pods -n rook-ceph -l app=rook-ceph-mon --field-selector=status.phase=Running --no-headers 2>/dev/null | wc -l | tr -d ' ' || echo "0"); \
		MGR_PODS=$$(kubectl get pods -n rook-ceph -l app=rook-ceph-mgr --field-selector=status.phase=Running --no-headers 2>/dev/null | wc -l | tr -d ' ' || echo "0"); \
		PHASE=$$(kubectl get cephcluster -n rook-ceph -o jsonpath='{.items[0].status.phase}' 2>/dev/null || echo ""); \
		MESSAGE=$$(kubectl get cephcluster -n rook-ceph -o jsonpath='{.items[0].status.message}' 2>/dev/null || echo ""); \
		if [ "$$MON_PODS" -ge 1 ] && [ "$$MGR_PODS" -ge 1 ]; then \
			if [ -n "$$PHASE" ] && [ "$$PHASE" = "Ready" ]; then \
				echo "✓ CephCluster is ready!"; \
				CLUSTER_READY=1; \
				break; \
			else \
				echo "✓ CephCluster has MON and MGR pods running, proceeding..."; \
				CLUSTER_READY=1; \
				break; \
			fi; \
		fi; \
		if [ "$$POD_STATUS" = "ImagePullBackOff" ] && [ $$RETRY_COUNT -lt 3 ]; then \
			if [ $$((i % 6)) -eq 0 ]; then \
				echo ""; \
				echo "⚠ Image pull failed, retrying (attempt $$((RETRY_COUNT + 1))/3)..."; \
				kubectl delete job -n rook-ceph rook-ceph-detect-version 2>/dev/null || true; \
				RETRY_COUNT=$$((RETRY_COUNT + 1)); \
				sleep 10; \
			fi; \
		fi; \
		if [ $$((i % 18)) -eq 0 ]; then \
			echo "[$$i/240] Waiting for CephCluster... ($$(date +%H:%M:%S))"; \
			echo "  Status: $${MESSAGE:-$$PHASE}"; \
			if [ "$$VERSION_JOB" != "True" ]; then \
				if [ "$$POD_STATUS" = "ImagePullBackOff" ]; then \
					echo "  Version detection: Image pull failed, will retry"; \
				else \
					echo "  Version detection: in progress (pulling large Ceph image, this can take 15+ minutes)"; \
				fi; \
			fi; \
			echo "  MON pods: $$MON_PODS, MGR pods: $$MGR_PODS"; \
		fi; \
		sleep 5; \
	done; \
	if [ $$CLUSTER_READY -eq 0 ]; then \
		echo ""; \
		echo "⚠ Warning: CephCluster not fully ready after 20 minutes, but continuing to check for secret..."; \
		echo "  This is normal if images are still being pulled."; \
	fi; \
	true
	@echo ""
	@echo "Step 6: Waiting for RGW secret to be populated..."
	@echo "This may take a few minutes..."
	@SECRET_NAME="rook-ceph-object-user-rgw-store-s3-user"; \
	USER_NAME="s3-user"; \
	echo "Waiting for secret '$$SECRET_NAME' to exist and contain credentials..."; \
	SECRET_READY=0; \
	for i in $$(seq 1 120); do \
		if kubectl get secret -n rook-ceph $$SECRET_NAME >/dev/null 2>&1; then \
			ACCESS_KEY_B64=$$(kubectl get secret -n rook-ceph $$SECRET_NAME -o jsonpath='{.data.AccessKey}' 2>/dev/null || echo ""); \
			SECRET_KEY_B64=$$(kubectl get secret -n rook-ceph $$SECRET_NAME -o jsonpath='{.data.SecretKey}' 2>/dev/null || echo ""); \
			if [ -n "$$ACCESS_KEY_B64" ] && [ -n "$$SECRET_KEY_B64" ] && [ "$$ACCESS_KEY_B64" != "" ] && [ "$$SECRET_KEY_B64" != "" ]; then \
				echo "✓ RGW credentials are ready!"; \
				SECRET_READY=1; \
				break; \
			fi; \
		fi; \
		if [ $$((i % 12)) -eq 0 ]; then \
			echo "[$$i/120] Waiting... ($$(date +%H:%M:%S))"; \
			if kubectl get secret -n rook-ceph $$SECRET_NAME >/dev/null 2>&1; then \
				echo "  Secret exists, waiting for data..."; \
			else \
				echo "  Secret does not exist yet..."; \
				RGW_PODS=$$(kubectl get pods -n rook-ceph -l app=rook-ceph-rgw --field-selector=status.phase=Running --no-headers 2>/dev/null | wc -l | tr -d ' ' || echo "0"); \
				echo "  RGW pods running: $$RGW_PODS"; \
			fi; \
		fi; \
		sleep 5; \
	done; \
	if [ $$SECRET_READY -eq 0 ]; then \
		echo ""; \
		echo "❌ Error: RGW secret not ready after 10 minutes."; \
		echo ""; \
		echo "Diagnostics:"; \
		echo "  Secret exists: $$(kubectl get secret -n rook-ceph $$SECRET_NAME >/dev/null 2>&1 && echo 'yes' || echo 'no')"; \
		if kubectl get secret -n rook-ceph $$SECRET_NAME >/dev/null 2>&1; then \
			echo "  Has AccessKey: $$(kubectl get secret -n rook-ceph $$SECRET_NAME -o jsonpath='{.data.AccessKey}' 2>/dev/null | grep -q . && echo 'yes' || echo 'no')"; \
			echo "  Has SecretKey: $$(kubectl get secret -n rook-ceph $$SECRET_NAME -o jsonpath='{.data.SecretKey}' 2>/dev/null | grep -q . && echo 'yes' || echo 'no')"; \
		fi; \
		echo "  CephObjectStoreUser phase: $$(kubectl get cephobjectstoreuser -n rook-ceph $$USER_NAME -o jsonpath='{.status.phase}' 2>/dev/null || echo 'unknown')"; \
		echo "  CephObjectStore phase: $$(kubectl get cephobjectstore -n rook-ceph rgw-store -o jsonpath='{.status.phase}' 2>/dev/null || echo 'unknown')"; \
		echo "  CephCluster phase: $$(kubectl get cephcluster -n rook-ceph -o jsonpath='{.items[0].status.phase}' 2>/dev/null || echo 'unknown')"; \
		echo "  RGW pods: $$(kubectl get pods -n rook-ceph -l app=rook-ceph-rgw --field-selector=status.phase=Running --no-headers 2>/dev/null | wc -l | tr -d ' ' || echo '0')"; \
		echo ""; \
		echo "Troubleshooting:"; \
		echo "1. Check Rook operator logs: kubectl logs -n rook-ceph -l app=rook-ceph-operator --tail=50"; \
		echo "2. Check CephObjectStoreUser: kubectl describe cephobjectstoreuser -n rook-ceph $$USER_NAME"; \
		echo "3. Check CephObjectStore: kubectl describe cephobjectstore -n rook-ceph rgw-store"; \
		echo "4. Check CephCluster: kubectl describe cephcluster -n rook-ceph rook-ceph"; \
		echo "5. Wait longer and retry: make apply-foundation"; \
		exit 1; \
	fi
	@echo ""
	@echo "Step 7: Applying RGW Bootstrap (stores credentials in Vault)..."
	@cd iac/envs/$(ENV) && tofu apply \
		-target='module.rgw_bootstrap' \
		-target='data.vault_kv_secret_v2.rgw_credentials' \
		-auto-approve
	@echo ""
	@echo "✓ Foundation layer complete!"
	@echo ""
	@echo "Next steps:"
	@echo "1. Export RGW credentials to environment variables:"
	@echo "   eval \$$(vault kv get -format=json secret/rgw/credentials | jq -r '.data.data | \"export AWS_ACCESS_KEY_ID=\(.access_key)\nexport AWS_SECRET_ACCESS_KEY=\(.secret_key)\"')"
	@echo ""
	@echo "2. Apply services layer:"
	@echo "   make apply-services"

apply-services: ## Apply services layer (S3 buckets, observability, applications - requires credentials in env vars)
	@echo "=========================================="
	@echo "Services Layer: S3 Buckets + Applications"
	@echo "=========================================="
	@if [ -z "$$AWS_ACCESS_KEY_ID" ] || [ -z "$$AWS_SECRET_ACCESS_KEY" ]; then \
		echo "Error: AWS_ACCESS_KEY_ID and AWS_SECRET_ACCESS_KEY must be set"; \
		echo "Run: eval \$$(vault kv get -format=json secret/rgw/credentials | jq -r '.data.data | \"export AWS_ACCESS_KEY_ID=\(.access_key)\nexport AWS_SECRET_ACCESS_KEY=\(.secret_key)\"')"; \
		exit 1; \
	fi
	@echo "Applying S3 buckets and remaining infrastructure..."
	@cd iac/envs/$(ENV) && tofu apply \
		-exclude='module.rook_ceph' \
		-exclude='module.vault' \
		-exclude='module.rgw_bootstrap' \
		-exclude='data.vault_kv_secret_v2.rgw_credentials' \
		-auto-approve
	@echo ""
	@echo "✓ Services layer complete!"

apply: ensure-rook-crds ## Apply all infrastructure (runs foundation + services sequentially)
	@$(MAKE) apply-foundation
	@echo ""
	@echo "Waiting 10 seconds for Vault to be ready..."
	@sleep 10
	@echo ""
	@echo "Exporting credentials..."
	@eval $$(vault kv get -format=json secret/rgw/credentials 2>/dev/null | jq -r '.data.data | "export AWS_ACCESS_KEY_ID=\(.access_key)\nexport AWS_SECRET_ACCESS_KEY=\(.secret_key)"') || { \
		echo "Warning: Could not export credentials from Vault. Please export manually:"; \
		echo "  vault kv get -format=json secret/rgw/credentials | jq -r '.data.data | \"export AWS_ACCESS_KEY_ID=\(.access_key)\nexport AWS_SECRET_ACCESS_KEY=\(.secret_key)\"'"; \
		exit 1; \
	}
	@$(MAKE) apply-services

destroy: ## Destroy Terraform infrastructure
	@cd iac/envs/$(ENV) && tofu destroy

init: ## Initialize Terraform
	@cd iac/envs/$(ENV) && tofu init

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
local-setup: ## Set up complete local development environment (Kind cluster)
	@echo "Setting up local development environment..."
	@$(MAKE) kind-up
	@echo ""
	@echo "✓ Local development environment is ready!"
	@echo ""
	@echo "Note: S3-compatible storage is provided by Rook-Ceph RGW (no LocalStack needed)"
	@echo ""
	@echo "Next steps:"
	@echo "  1. cd iac/envs/local"
	@echo "  2. make init"
	@echo "  3. make plan"
	@echo "  4. make apply"

local-teardown: ## Tear down local development environment
	@echo "Tearing down local development environment..."
	@$(MAKE) kind-down
	@echo "✓ Local development environment torn down"

prepull-ceph-image: ## Pre-pull Ceph image with resumable download (handles network failures gracefully)
	@echo "Pre-pulling Ceph image (resumable - will resume if network fails)..."
	@echo "Note: containerd automatically resumes partial downloads"
	@echo ""
	@NODE="local-worker"; \
	IMAGE="quay.io/ceph/ceph:v18.2.0"; \
	echo "Pulling $$IMAGE on node $$NODE..."; \
	echo "If network fails, just run 'make prepull-ceph-image' again - it will resume"; \
	echo ""; \
	if docker exec "$$NODE" crictl pull "$$IMAGE" 2>&1; then \
		echo ""; \
		echo "✓ Image pulled successfully!"; \
		docker exec "$$NODE" crictl images | grep "$$IMAGE" || true; \
	else \
		EXIT_CODE=$$?; \
		echo ""; \
		echo "⚠ Pull failed or interrupted (exit code: $$EXIT_CODE)"; \
		echo "  Containerd has cached partial layers - run 'make prepull-ceph-image' again to resume"; \
		echo "  Or wait for the automatic retry in make apply-foundation"; \
		exit $$EXIT_CODE; \
	fi
