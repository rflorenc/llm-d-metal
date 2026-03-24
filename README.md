# llm-d-metal

POC: llm-d inference scheduling with vllm-metal on Apple Silicon.

## Architecture

```
┌─── Kind Cluster ─────────────────────────────────────┐
│                                                       │
│  Gateway (AgentGateway + Envoy)                      │
│       │                                               │
│  HTTPRoute → InferencePool                           │
│       │                                               │
│  llm-d-inference-scheduler (EPP)                     │
│       │                                               │
│  vllm-metal-proxy (nginx)                            │
│  Labels: llm-d.ai/inference-serving: "true"          │
│       │ proxy_pass → host.docker.internal:8000       │
└───────┼───────────────────────────────────────────────┘
        │
        ▼
┌─── Native macOS ─────────────────────────────────────┐
│  vllm-metal serve <model> (Metal GPU)                │
│  http://0.0.0.0:8000                                 │
│  OpenAI-compatible API + /health + /metrics          │
└──────────────────────────────────────────────────────┘
```

Since InferencePool discovers backends via Kubernetes pod label selectors,
we deploy a lightweight nginx proxy pod inside Kind that forwards traffic
to vllm-metal running natively on the Mac via `host.docker.internal`.

## Prerequisites

- macOS on Apple Silicon (M1+)
- [vllm-metal](https://github.com/vllm-project/vllm-metal) installed and working
- Docker Desktop (with Kind support)
- [kind](https://kind.sigs.k8s.io/)
- [kubectl](https://kubernetes.io/docs/tasks/tools/)
- [helm](https://helm.sh/docs/intro/install/)
- [helmfile](https://github.com/helmfile/helmfile)

## Quick Start

```bash
# 1. Start vllm-metal natively (in a separate terminal)
source /path/to/.venv-vllm-metal/bin/activate
GLOO_SOCKET_IFNAME=lo0 vllm serve HuggingFaceTB/SmolLM2-135M-Instruct

# 2. Create the Kind cluster and deploy llm-d components
./scripts/setup.sh

# 3. Test inference through the llm-d gateway
./scripts/test.sh
```

## Components

| Component | Runs on | Purpose |
|-----------|---------|---------|
| vllm-metal | Native macOS | Model inference on Metal GPU |
| nginx proxy | Kind pod | Bridges K8s pod discovery to host |
| AgentGateway | Kind pod | Gateway + Envoy data plane |
| llm-d-inference-scheduler | Kind pod | Intelligent request routing (EPP) |
| InferencePool CRD | Kind | Defines the inference topology |
| HTTPRoute | Kind | Routes gateway traffic to pool |
