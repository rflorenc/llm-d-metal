#!/bin/bash
set -eu -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
CLUSTER_NAME="llm-d-metal"
NAMESPACE="llm-d-metal"

GATEWAY_API_VERSION="v1.5.1"
INFERENCE_EXT_VERSION="v1.4.0"

echo "=== Step 1: Create Kind cluster ==="
if kind get clusters 2>/dev/null | grep -q "^${CLUSTER_NAME}$"; then
  echo "Cluster '${CLUSTER_NAME}' already exists, skipping creation."
else
  kind create cluster --config "${ROOT_DIR}/kind-config.yaml"
fi

echo ""
echo "=== Step 2: Install Gateway API CRDs ==="
kubectl apply -f "https://github.com/kubernetes-sigs/gateway-api/releases/download/${GATEWAY_API_VERSION}/standard-install.yaml"

echo ""
echo "=== Step 3: Install Gateway API Inference Extension CRDs ==="
kubectl apply -f "https://github.com/kubernetes-sigs/gateway-api-inference-extension/releases/download/${INFERENCE_EXT_VERSION}/manifests.yaml"

echo ""
echo "=== Step 4: Install Istio (gateway control plane) ==="
if ! command -v istioctl &> /dev/null; then
  echo "Installing istioctl..."
  brew install istioctl
fi
istioctl install --set profile=minimal -y
# Enable Istio sidecar injection in our namespace (optional, not required for gateway)

echo ""
echo "=== Step 5: Create namespace ==="
kubectl apply -f "${ROOT_DIR}/manifests/namespace.yaml"

echo ""
echo "=== Step 6: Build and load proxy image into Kind ==="
docker build -t vllm-metal-proxy:latest "${ROOT_DIR}/proxy/"
kind load docker-image vllm-metal-proxy:latest --name "${CLUSTER_NAME}"

echo ""
echo "=== Step 7: Deploy proxy ==="
kubectl apply -f "${ROOT_DIR}/manifests/vllm-metal-proxy.yaml"

echo ""
echo "=== Step 8: Deploy EPP (llm-d-inference-scheduler) ==="
kubectl apply -f "${ROOT_DIR}/manifests/epp-config.yaml"
kubectl apply -f "${ROOT_DIR}/manifests/epp-rbac.yaml"
kubectl apply -f "${ROOT_DIR}/manifests/epp-deployment.yaml"

echo ""
echo "=== Step 9: Deploy Gateway ==="
kubectl apply -f "${ROOT_DIR}/manifests/gateway.yaml"

echo ""
echo "=== Step 10: Deploy InferencePool ==="
kubectl apply -f "${ROOT_DIR}/manifests/inference-pool.yaml"

echo ""
echo "=== Step 11: Deploy HTTPRoute ==="
kubectl apply -f "${ROOT_DIR}/manifests/httproute.yaml"

echo ""
echo "=== Waiting for pods to be ready ==="
kubectl wait --for=condition=ready pod \
  -l app=vllm-metal-proxy \
  -n "${NAMESPACE}" \
  --timeout=60s
kubectl wait --for=condition=ready pod \
  -l app=vllm-metal-epp \
  -n "${NAMESPACE}" \
  --timeout=120s

echo ""
echo "=== Status ==="
kubectl get all -n "${NAMESPACE}"
kubectl get gateway,httproute,inferencepool -n "${NAMESPACE}"

echo ""
echo "============================================"
echo " Setup complete!"
echo ""
echo " Make sure vllm-metal is running natively:"
echo "   GLOO_SOCKET_IFNAME=lo0 vllm serve HuggingFaceTB/SmolLM2-135M-Instruct"
echo ""
echo " Then test via the gateway:"
echo "   ./scripts/test.sh"
echo "============================================"
