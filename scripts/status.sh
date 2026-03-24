#!/bin/bash
set -eu -o pipefail

echo "=== Pods (default namespace) ==="
kubectl get pods -o wide

echo ""
echo "=== Pods (llm-d-istio-system) ==="
kubectl get pods -n llm-d-istio-system -o wide 2>/dev/null || echo "No Istio namespace"

echo ""
echo "=== Gateway ==="
kubectl get gateway -o wide 2>/dev/null || echo "No gateways found"

echo ""
echo "=== HTTPRoute ==="
kubectl get httproute -o wide 2>/dev/null || echo "No httproutes found"

echo ""
echo "=== InferencePool ==="
kubectl get inferencepool -o wide 2>/dev/null || echo "No inference pools found"

echo ""
echo "=== Services ==="
kubectl get svc

echo ""
echo "=== EPP logs (last 10 lines) ==="
kubectl logs -l component=epp --tail=10 2>/dev/null || echo "No EPP logs"

echo ""
echo "=== Proxy logs (last 10 lines) ==="
kubectl logs -l component=proxy --tail=10 2>/dev/null || echo "No proxy logs"
