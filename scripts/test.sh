#!/bin/bash
set -eu -o pipefail

NAMESPACE="llm-d-metal"
MODEL="HuggingFaceTB/SmolLM2-135M-Instruct"

echo "=== Checking vllm-metal is reachable from proxy ==="
kubectl exec -n "${NAMESPACE}" deploy/vllm-metal-proxy -- \
  wget -qO- http://host.docker.internal:8000/health || {
    echo "ERROR: Cannot reach vllm-metal on host. Is it running?"
    echo "  GLOO_SOCKET_IFNAME=lo0 vllm serve ${MODEL}"
    exit 1
  }
echo "OK"

echo ""
echo "=== Testing direct proxy access (port-forward) ==="
# Port-forward the proxy pod
kubectl port-forward -n "${NAMESPACE}" deploy/vllm-metal-proxy 9000:8000 &
PF_PID=$!
sleep 2

echo "Sending chat completion request via proxy..."
RESPONSE=$(curl -s http://localhost:9000/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d "{
    \"model\": \"${MODEL}\",
    \"messages\": [{\"role\": \"user\", \"content\": \"Say hello\"}],
    \"max_tokens\": 32
  }")

kill $PF_PID 2>/dev/null || true

if echo "$RESPONSE" | grep -q '"choices"'; then
  echo "Proxy -> vllm-metal: PASS"
  echo "$RESPONSE" | python3 -m json.tool 2>/dev/null || echo "$RESPONSE"
else
  echo "Proxy -> vllm-metal: FAIL"
  echo "$RESPONSE"
  exit 1
fi

echo ""
echo "=== Testing via Gateway (if available) ==="
GATEWAY_IP=$(kubectl get gateway llm-d-metal-gateway -n "${NAMESPACE}" \
  -o jsonpath='{.status.addresses[0].value}' 2>/dev/null || echo "")

if [ -n "$GATEWAY_IP" ]; then
  echo "Gateway IP: $GATEWAY_IP"
  curl -s "http://${GATEWAY_IP}/v1/chat/completions" \
    -H "Content-Type: application/json" \
    -d "{
      \"model\": \"${MODEL}\",
      \"messages\": [{\"role\": \"user\", \"content\": \"Say hello\"}],
      \"max_tokens\": 32
    }" | python3 -m json.tool 2>/dev/null
else
  echo "Gateway not yet assigned an address. Try port-forwarding:"
  echo "  kubectl port-forward -n ${NAMESPACE} svc/llm-d-metal-gateway-istio 8080:80"
  echo "  curl http://localhost:8080/v1/chat/completions ..."
fi

echo ""
echo "=== Done ==="
