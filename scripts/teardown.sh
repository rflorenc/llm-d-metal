#!/bin/bash
set -eu -o pipefail

CLUSTER_NAME="llm-d-metal"

echo "Deleting Kind cluster '${CLUSTER_NAME}'..."
kind delete cluster --name "${CLUSTER_NAME}"
echo "Done."
