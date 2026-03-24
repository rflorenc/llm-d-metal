# llm-d-metal

POC: llm-d inference scheduling with vllm-metal on Apple Silicon.

## Architecture

```
curl :8080 → Kind NodePort → Envoy → ext-proc gRPC → EPP (picks endpoint)
  → nginx proxy pod → host.docker.internal:8000 → vllm-metal (Metal GPU)
```

The nginx proxy pod is labeled for InferencePool discovery. Envoy consults the
llm-d-inference-scheduler (EPP) via ext-proc before routing each request.
Istio runs the `llm-d-gateway` revision with `ENABLE_GATEWAY_API_INFERENCE_EXTENSION=true`.

## Prerequisites

- macOS on Apple Silicon (M1+)
- [vllm-metal](https://github.com/vllm-project/vllm-metal) installed and working
- [Docker Desktop](https://www.docker.com/products/docker-desktop/) (for Kind)

Install the CLI tools:

```bash
brew install kind kubectl
```

CRDs and the Istio control plane are fetched from [llm-d-inference-scheduler](https://github.com/llm-d/llm-d-inference-scheduler)


## Quick Start

```bash
# 1. separate terminal start vllm-metal natively 
GLOO_SOCKET_IFNAME=lo0 vllm serve HuggingFaceTB/SmolLM2-135M-Instruct

# 2. deploy the full llm-d stack in Kind
./scripts/setup.sh

# 3. test
./scripts/test.sh
```

## Traffic flow

Send a request through the gateway and trace it through each component.

### 1. Send a request

```bash
curl -s http://localhost:8080/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{"model":"HuggingFaceTB/SmolLM2-135M-Instruct","messages":[{"role":"user","content":"Say hello"}],"max_tokens":32}'
```

### 2. Check the proxy logs

The nginx proxy logs show requests arriving from the Envoy gateway and
being forwarded to vllm-metal on the host:

```bash
kubectl logs deploy/vllm-metal-proxy --tail=5
```

### 3. Check the Envoy gateway logs

Look for ext-proc activity. Successful requests show no errors.
If ext-proc can't reach the EPP you'll see `Connection refused` warnings:

```bash
kubectl logs -l gateway.networking.k8s.io/gateway-name=inference-gateway --tail=10
```

### 4. Check the EPP logs

The EPP logs show controller startup and ext-proc gRPC activity:

```bash
kubectl logs -l component=epp --tail=10
```

## Querying EPP Prometheus metrics

The EPP exposes Prometheus metrics on port 9090. These are the definitive
proof that Envoy is consulting the EPP via ext-proc for routing decisions.

### Port-forward to the EPP metrics endpoint

```bash
EPP_POD=$(kubectl get pods -l component=epp -o jsonpath='{.items[0].metadata.name}')
kubectl port-forward $EPP_POD 19090:9090 &
```

### Key metrics

**Request count** — increments each time Envoy calls the EPP via ext-proc:

```bash
curl -s http://localhost:19090/metrics | grep inference_objective_request_total
# inference_objective_request_total{model_name="HuggingFaceTB/SmolLM2-135M-Instruct",...} 3
```

**Ready pods** — how many endpoints the EPP sees in the InferencePool:

```bash
curl -s http://localhost:19090/metrics | grep inference_pool_ready_pods
# inference_pool_ready_pods{name="vllm-metal-pool"} 1
```

### Verify ext-proc is in the path

Send a request and confirm the request count increases:

```bash
# Before
curl -s http://localhost:19090/metrics | grep inference_objective_request_total

# Send a request
curl -s http://localhost:8080/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{"model":"HuggingFaceTB/SmolLM2-135M-Instruct","messages":[{"role":"user","content":"hello"}],"max_tokens":8}' > /dev/null

# count should have increased by 1 ...
curl -s http://localhost:19090/metrics | grep inference_objective_request_total
```

The `./scripts/test.sh` script automates this check.

## Notes

- Gateway, HTTPRoute, InferencePool, and EPP RBAC are sourced from
  `llm-d-inference-scheduler/deploy/components/` via kustomize.
- UDS tokenizer sidecar is omitted so prefix-cache scoring likely won't work, but load-balanced routing does.
