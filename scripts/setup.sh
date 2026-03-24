#!/bin/bash
set -eu -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
CLUSTER_NAME="llm-d-metal"
EPP_IMAGE="ghcr.io/llm-d/llm-d-inference-scheduler:latest"

# Remote kustomize references (no local clone needed)
SCHEDULER_REPO="https://github.com/llm-d/llm-d-inference-scheduler"
SCHEDULER_REF="main"

echo "1: Create Kind cluster ==="
if kind get clusters 2>/dev/null | grep -q "^${CLUSTER_NAME}$"; then
  echo "Cluster '${CLUSTER_NAME}' already exists, skipping creation."
else
  kind create cluster --config "${ROOT_DIR}/kind-config.yaml"
fi

echo ""
echo "2: Install CRDs ==="
kubectl kustomize "${SCHEDULER_REPO}/deploy/components/crds-gateway-api?ref=${SCHEDULER_REF}" \
  | kubectl apply --server-side --force-conflicts -f -

kubectl kustomize "${SCHEDULER_REPO}/deploy/components/crds-gie?ref=${SCHEDULER_REF}" \
  | kubectl apply --server-side --force-conflicts -f -

kubectl kustomize --enable-helm "${SCHEDULER_REPO}/deploy/components/crds-istio?ref=${SCHEDULER_REF}" \
  | kubectl apply --server-side --force-conflicts -f -

echo ""
echo "3: Deploy Istio control plane (llm-d-gateway revision) ==="
kubectl kustomize "${SCHEDULER_REPO}/deploy/components/istio-control-plane?ref=${SCHEDULER_REF}" \
  | kubectl apply --server-side --force-conflicts -f -

echo "Waiting for Istiod to be ready..."
kubectl -n llm-d-istio-system wait --for=condition=available --timeout=300s deployment --all

echo ""
echo "4: Build and load proxy image into Kind ==="
docker build -t vllm-metal-proxy:latest "${ROOT_DIR}/proxy/"
kind load docker-image vllm-metal-proxy:latest --name "${CLUSTER_NAME}"

echo ""
echo "5: Pull and load EPP image into Kind ==="
LINUX_ARCH="$(uname -m)"
case "${LINUX_ARCH}" in
    x86_64) LINUX_ARCH="amd64" ;;
    aarch64|arm64) LINUX_ARCH="arm64" ;;
esac

docker pull --platform "linux/${LINUX_ARCH}" "${EPP_IMAGE}" 2>/dev/null || true
docker save --platform "linux/${LINUX_ARCH}" "${EPP_IMAGE}" \
  | kind --name "${CLUSTER_NAME}" load image-archive /dev/stdin

echo ""
echo "6: Deploy manifests ==="
kubectl apply -f "${ROOT_DIR}/manifests/vllm-metal-proxy.yaml"
kubectl apply -f "${ROOT_DIR}/manifests/epp-config.yaml"
kubectl apply -f "${ROOT_DIR}/manifests/epp-rbac.yaml"
kubectl apply -f "${ROOT_DIR}/manifests/epp-service.yaml"
kubectl apply -f "${ROOT_DIR}/manifests/epp-deployment.yaml"
kubectl apply -f "${ROOT_DIR}/manifests/inference-pool.yaml"
kubectl apply -f "${ROOT_DIR}/manifests/httproute.yaml"
kubectl apply -f "${ROOT_DIR}/manifests/gateway.yaml"
kubectl apply -f "${ROOT_DIR}/manifests/gateway-nodeport.yaml"
kubectl apply -f "${ROOT_DIR}/manifests/destination-rule.yaml"

echo ""
echo "=== Waiting for pods to be ready ==="
echo "Waiting for proxy..."
kubectl wait --for=condition=ready pod \
  -l component=proxy \
  --timeout=180s

echo "Waiting for EPP..."
kubectl wait --for=condition=ready pod \
  -l component=epp \
  --timeout=180s

echo "Waiting for gateway..."
kubectl wait --for=condition=ready pod \
  -l gateway.networking.k8s.io/gateway-name=inference-gateway \
  --timeout=180s

echo ""
echo "=== Status ==="
kubectl get pods -o wide
kubectl get gateway,httproute,inferencepool
echo ""
kubectl get pods -n llm-d-istio-system

echo ""
echo "============================================"
echo " Setup complete!"
echo ""
echo " Make sure vllm-metal is running natively:"
echo "   GLOO_SOCKET_IFNAME=lo0 vllm serve HuggingFaceTB/SmolLM2-135M-Instruct"
echo ""
echo " Test the full gateway path:"
echo "   curl http://localhost:8080/v1/chat/completions \\"
echo "     -H 'Content-Type: application/json' \\"
echo "     -d '{\"model\":\"HuggingFaceTB/SmolLM2-135M-Instruct\",\"messages\":[{\"role\":\"user\",\"content\":\"Say hello\"}],\"max_tokens\":32}'"
echo ""
echo " Or run: ./scripts/test.sh"
echo "============================================"
