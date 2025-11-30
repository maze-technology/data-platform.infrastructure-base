#!/usr/bin/env bash
set -euo pipefail

# Script to create and configure a kind cluster for local development
# Usage: ./scripts/kind-up.sh [cluster-name]

CLUSTER_NAME="${1:-local}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KIND_CONFIG="${SCRIPT_DIR}/kind-config.yaml"

echo "Creating kind cluster: ${CLUSTER_NAME}"

# Check if kind is installed
if ! command -v kind &> /dev/null; then
  echo "Error: kind is not installed. Please install it first:"
  echo "  https://kind.sigs.k8s.io/docs/user/quick-start/#installation"
  exit 1
fi

# Check if cluster already exists
if kind get clusters | grep -q "^${CLUSTER_NAME}$"; then
  echo "Cluster ${CLUSTER_NAME} already exists. Use 'kind delete cluster --name ${CLUSTER_NAME}' to remove it first."
  exit 1
fi

# Create cluster with config if it exists, otherwise use defaults
if [ -f "${KIND_CONFIG}" ]; then
  echo "Using kind configuration from ${KIND_CONFIG}"
  kind create cluster --name "${CLUSTER_NAME}" --config "${KIND_CONFIG}"
else
  echo "Creating cluster with default configuration"
  kind create cluster --name "${CLUSTER_NAME}"
fi

# Set kubectl context
kubectl cluster-info --context "kind-${CLUSTER_NAME}"

echo ""
echo "✓ Kind cluster '${CLUSTER_NAME}' created successfully!"
echo ""
echo "Next steps:"
echo "  1. cd iac/envs/local"
echo "  2. tofu init"
echo "  3. tofu plan"
echo "  4. tofu apply"
echo ""

