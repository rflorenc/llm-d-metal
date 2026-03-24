#!/bin/bash
set -eu -o pipefail

MODEL="HuggingFaceTB/SmolLM2-135M-Instruct"
EPP_POD=$(kubectl get pods -l component=epp -o jsonpath='{.items[0].metadata.name}')

# Clean up any stale port-forwards on exit
cleanup() { kill $(jobs -p) 2>/dev/null || true; }
trap cleanup EXIT

echo "=== 1. Checking vllm-metal is reachable from proxy ==="
kubectl exec deploy/vllm-metal-proxy -- \
  wget -qO- http://host.docker.internal:8000/health || {
    echo "FAIL: Cannot reach vllm-metal. Is it running?"
    exit 1
  }
echo "OK"

echo ""
echo "=== 2. Get EPP request count before test ==="
kubectl port-forward "$EPP_POD" 19090:9090 &
PF_METRICS_PID=$!
sleep 2

BEFORE=$(curl -s http://localhost:19090/metrics | \
  python3 -c "
import sys
for l in sys.stdin:
    if 'inference_objective_request_total' in l and not l.startswith('#'):
        print(l.strip().split()[-1]); break
else:
    print('0')
")
echo "Requests before: ${BEFORE}"

kill $PF_METRICS_PID 2>/dev/null || true

echo ""
echo "=== 3. Send request through the gateway ==="
RESPONSE=$(curl -s --max-time 15 http://localhost:8080/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d "{
    \"model\": \"${MODEL}\",
    \"messages\": [{\"role\": \"user\", \"content\": \"Say hello\"}],
    \"max_tokens\": 32
  }" 2>&1)

if echo "$RESPONSE" | python3 -c "import sys,json; json.load(sys.stdin)['choices']" >/dev/null 2>&1; then
  echo "Gateway response: PASS"
  echo "$RESPONSE" | python3 -m json.tool 2>/dev/null
else
  echo "Gateway response: FAIL"
  echo "$RESPONSE"
  exit 1
fi

echo ""
echo "=== 4. Verify EPP processed the request (ext-proc proof) ==="
kubectl port-forward "$EPP_POD" 19091:9090 &
PF_METRICS_PID=$!
sleep 2

AFTER=$(curl -s http://localhost:19091/metrics | \
  python3 -c "
import sys
for l in sys.stdin:
    if 'inference_objective_request_total' in l and not l.startswith('#'):
        print(l.strip().split()[-1]); break
else:
    print('0')
")

# Show relevant EPP metrics
echo "EPP metrics:"
curl -s http://localhost:19091/metrics | python3 -c "
import sys
for l in sys.stdin:
    s = l.strip()
    if s and not s.startswith('#') and ('inference_objective_request_total' in s or 'inference_pool_ready_pods' in s):
        print('  ' + s)
"

kill $PF_METRICS_PID 2>/dev/null || true

echo ""
echo "Requests before: ${BEFORE}, after: ${AFTER}"

if python3 -c "exit(0 if float('${AFTER}') > float('${BEFORE}') else 1)"; then
  echo "EPP ext-proc routing: PASS"
else
  echo "EPP ext-proc routing: FAIL (request count did not increase)"
  exit 1
fi

echo ""
echo "=== Full path verified ==="
echo "curl :8080 -> Envoy -> ext-proc -> EPP -> proxy pod -> vllm-metal (Metal GPU)"
