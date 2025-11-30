#!/usr/bin/env bash
set -euo pipefail

# Script to delete a kind cluster
# Usage: ./scripts/kind-down.sh [cluster-name]

CLUSTER_NAME="${1:-local}"

echo "Deleting kind cluster: ${CLUSTER_NAME}"

# Check if kind is installed
if ! command -v kind &> /dev/null; then
  echo "Error: kind is not installed."
  exit 1
fi

# Check if cluster exists
if ! kind get clusters | grep -q "^${CLUSTER_NAME}$"; then
  echo "Cluster ${CLUSTER_NAME} does not exist."
  exit 1
fi

# Delete cluster
kind delete cluster --name "${CLUSTER_NAME}"

echo "✓ Kind cluster '${CLUSTER_NAME}' deleted successfully!"

