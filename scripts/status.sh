#!/bin/bash
set -eu -o pipefail

NAMESPACE="llm-d-metal"

echo "=== Pods ==="
kubectl get pods -n "${NAMESPACE}" -o wide

echo ""
echo "=== Gateway ==="
kubectl get gateway -n "${NAMESPACE}" -o wide 2>/dev/null || echo "No gateways found"

echo ""
echo "=== HTTPRoute ==="
kubectl get httproute -n "${NAMESPACE}" -o wide 2>/dev/null || echo "No httproutes found"

echo ""
echo "=== InferencePool ==="
kubectl get inferencepool -n "${NAMESPACE}" -o wide 2>/dev/null || echo "No inference pools found"

echo ""
echo "=== Proxy logs (last 20 lines) ==="
kubectl logs -n "${NAMESPACE}" deploy/vllm-metal-proxy --tail=20 2>/dev/null || echo "No proxy logs"
