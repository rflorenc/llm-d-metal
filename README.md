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
- Docker Desktop, [kind](https://kind.sigs.k8s.io/), [kubectl](https://kubernetes.io/docs/tasks/tools/), [envsubst](https://www.gnu.org/software/gettext/) (`brew install gettext`)
- [llm-d-inference-scheduler](https://github.com/llm-d/llm-d-inference-scheduler) cloned as sibling dir

## Quick Start

```bash
# 1. Start vllm-metal natively (separate terminal)
GLOO_SOCKET_IFNAME=lo0 vllm serve HuggingFaceTB/SmolLM2-135M-Instruct

# 2. Deploy the full llm-d stack in Kind
./scripts/setup.sh

# 3. Test
./scripts/test.sh
```

## Verifying the ext-proc path

The test script verifies the EPP is in the data path by checking its
`inference_objective_request_total` Prometheus metric before and after
sending a request through the gateway. If the count increases, Envoy
called the EPP via ext-proc to make the routing decision.

```bash
# Manual verification
EPP_POD=$(kubectl get pods -l component=epp -o jsonpath='{.items[0].metadata.name}')
kubectl port-forward $EPP_POD 9091:9090 &
curl -s http://localhost:9091/metrics | grep inference_objective_request_total
```

## Directory layout

```
├── kind-config.yaml              # Kind cluster (NodePort 8080→30080)
├── proxy/
│   ├── Dockerfile                # nginx alpine
│   └── nginx.conf                # proxy_pass → host.docker.internal:8000
├── manifests/
│   ├── vllm-metal-proxy.yaml     # Proxy Deployment (labeled for InferencePool)
│   ├── epp-config.yaml           # EPP scheduling plugins (ConfigMap)
│   └── epp-deployment.yaml       # EPP without UDS tokenizer sidecar
└── scripts/
    ├── setup.sh                  # Full cluster + deploy
    ├── test.sh                   # End-to-end + ext-proc verification
    ├── status.sh                 # Quick status check
    └── teardown.sh               # Cleanup
```

## Notes

- Gateway, HTTPRoute, InferencePool, and EPP RBAC are sourced from
  `llm-d-inference-scheduler/deploy/components/` via kustomize.
- UDS tokenizer sidecar is omitted — prefix-cache scoring won't work,
  but load-balanced routing does.
