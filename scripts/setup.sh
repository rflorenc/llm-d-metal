#!/bin/bash
set -eu -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
CLUSTER_NAME="llm-d-metal"

# llm-d-inference-scheduler repo (for Istio control plane + inference gateway kustomize)
SCHEDULER_ROOT="${SCHEDULER_ROOT:-$(cd "$ROOT_DIR/../llm-d-inference-scheduler" && pwd)}"

# EPP and pool naming (matches scheduler repo conventions)
export POOL_NAME="vllm-metal-pool"
export EPP_NAME="vllm-metal-pool"
export EPP_IMAGE="ghcr.io/llm-d/llm-d-inference-scheduler:latest"
export TARGET_PORTS="8000"

if [ ! -d "${SCHEDULER_ROOT}" ]; then
  echo "ERROR: llm-d-inference-scheduler repo not found at ${SCHEDULER_ROOT}"
  echo "Clone it or set SCHEDULER_ROOT env var."
  exit 1
fi

echo "=== Step 1: Create Kind cluster ==="
if kind get clusters 2>/dev/null | grep -q "^${CLUSTER_NAME}$"; then
  echo "Cluster '${CLUSTER_NAME}' already exists, skipping creation."
else
  kind create cluster --config "${ROOT_DIR}/kind-config.yaml"
fi

echo ""
echo "=== Step 2: Install CRDs ==="
kubectl kustomize "${SCHEDULER_ROOT}/deploy/components/crds-gateway-api" \
  | kubectl apply --server-side --force-conflicts -f -

kubectl kustomize "${SCHEDULER_ROOT}/deploy/components/crds-gie" \
  | kubectl apply --server-side --force-conflicts -f -

kubectl kustomize --enable-helm "${SCHEDULER_ROOT}/deploy/components/crds-istio" \
  | kubectl apply --server-side --force-conflicts -f -

echo ""
echo "=== Step 3: Deploy Istio control plane (llm-d-gateway revision) ==="
kubectl kustomize "${SCHEDULER_ROOT}/deploy/components/istio-control-plane" \
  | kubectl apply --server-side --force-conflicts -f -

echo "Waiting for Istiod to be ready..."
kubectl -n llm-d-istio-system wait --for=condition=available --timeout=300s deployment --all

echo ""
echo "=== Step 4: Build and load proxy image into Kind ==="
docker build -t vllm-metal-proxy:latest "${ROOT_DIR}/proxy/"
kind load docker-image vllm-metal-proxy:latest --name "${CLUSTER_NAME}"

echo ""
echo "=== Step 5: Pull and load EPP image into Kind ==="
LINUX_ARCH="$(uname -m)"
case "${LINUX_ARCH}" in
    x86_64) LINUX_ARCH="amd64" ;;
    aarch64|arm64) LINUX_ARCH="arm64" ;;
esac

docker pull --platform "linux/${LINUX_ARCH}" "${EPP_IMAGE}" 2>/dev/null || true
docker save --platform "linux/${LINUX_ARCH}" "${EPP_IMAGE}" \
  | kind --name "${CLUSTER_NAME}" load image-archive /dev/stdin

echo ""
echo "=== Step 6: Deploy vllm-metal proxy ==="
kubectl apply -f "${ROOT_DIR}/manifests/vllm-metal-proxy.yaml"

echo ""
echo "=== Step 7: Deploy EPP config ==="
kubectl apply -f "${ROOT_DIR}/manifests/epp-config.yaml"

echo ""
echo "=== Step 8: Deploy inference gateway (RBAC, Service, InferencePool, HTTPRoute) ==="
# Use the scheduler repo's kustomize for the inference-gateway component,
# but skip the Deployment (we deploy our own EPP without the UDS tokenizer).
kubectl kustomize "${SCHEDULER_ROOT}/deploy/components/inference-gateway" \
  | envsubst '${POOL_NAME} ${EPP_NAME} ${EPP_IMAGE} ${TARGET_PORTS}' \
  | kubectl apply -f - 2>&1 || true
# The above may fail on the Gateway (missing gatewayClassName) — that's expected,
# we create our own below. The RBAC, Service, InferencePool, and HTTPRoute succeed.

# Delete the kustomize-generated EPP deployment (has UDS tokenizer we don't need)
kubectl delete deployment "${POOL_NAME}" --ignore-not-found 2>/dev/null

# Patch EPP service selector to only target EPP pods (not the proxy)
kubectl patch svc "${EPP_NAME}" --type merge \
  -p '{"spec":{"selector":{"app":"'"${EPP_NAME}"'","component":"epp"}}}'

echo ""
echo "=== Step 9: Deploy Gateway with ext-proc labels ==="
cat <<'GATEWAY_EOF' | kubectl apply -f -
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: inference-gateway
  labels:
    istio.io/enable-inference-extproc: "true"
    istio.io/rev: llm-d-gateway
  annotations:
    networking.istio.io/service-type: ClusterIP
spec:
  gatewayClassName: istio
  listeners:
  - name: default
    port: 80
    protocol: HTTP
GATEWAY_EOF

# NodePort service for host access
cat <<'NP_EOF' | kubectl apply -f -
apiVersion: v1
kind: Service
metadata:
  annotations:
    networking.istio.io/service-type: NodePort
  labels:
    gateway.istio.io/managed: istio.io-gateway-controller
    gateway.networking.k8s.io/gateway-name: inference-gateway
    istio.io/enable-inference-extproc: "true"
  name: inference-gateway-istio-nodeport
spec:
  type: NodePort
  selector:
    gateway.networking.k8s.io/gateway-name: inference-gateway
  ports:
  - appProtocol: tcp
    name: status-port
    port: 15021
    protocol: TCP
    targetPort: 15021
    nodePort: 32021
  - appProtocol: http
    name: default
    port: 80
    protocol: TCP
    targetPort: 80
    nodePort: 30080
NP_EOF

echo ""
echo "=== Step 10: Deploy EPP (without UDS tokenizer) ==="
kubectl apply -f "${ROOT_DIR}/manifests/epp-deployment.yaml"

echo ""
echo "=== Step 11: DestinationRule (insecure TLS for dev) ==="
cat <<DR_EOF | kubectl apply -f -
apiVersion: networking.istio.io/v1
kind: DestinationRule
metadata:
  name: ${EPP_NAME}-insecure-tls
spec:
  host: ${EPP_NAME}
  trafficPolicy:
    tls:
      mode: SIMPLE
      insecureSkipVerify: true
DR_EOF

echo ""
echo "=== Waiting for pods to be ready ==="
kubectl wait --for=condition=ready pod \
  -l app=vllm-metal-pool \
  --timeout=120s

kubectl wait --for=condition=ready pod \
  -l app=vllm-metal-pool \
  -l app!=vllm-metal-proxy \
  --timeout=120s || true

echo "Waiting for gateway pod..."
sleep 5
kubectl wait --for=condition=ready pod \
  -l gateway.networking.k8s.io/gateway-name=inference-gateway \
  --timeout=120s || echo "Gateway pod not ready yet."

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
