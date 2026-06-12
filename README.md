# Project 2 — Multi-Model Serving + Request Routing (vLLM production-stack)

Project 2 of the AI-Infra plan: **2 models behind one request router**, deployed with the official
[vLLM production-stack Helm chart](https://github.com/vllm-project/production-stack) on the
Project 1 EKS cluster (`vllm-serving-eks`, us-east-1) scaled to **2x g6.xlarge** (one GPU per model).

**Checkpoint:** `curl` the *router* endpoint → both models answer through the same URL; requests
visibly distributed across backends; can explain routing modes in one sentence.

## Hardware

2× **g6.xlarge** GPU nodes (NVIDIA **L4, 24 GB VRAM** each, ~$0.805/hr) — one model per GPU,
scaled out from Project 1's single node. The router needs no GPU: it runs as a plain proxy on
the shared **m7i.large** CPU system node.

## Architecture
```
client ──► vllm-router-service (roundrobin)
              ├──► qwen-1p5b engine  (GPU node 1)  Qwen2.5-1.5B-Instruct
              └──► qwen-7b-awq engine (GPU node 2) Qwen2.5-7B-Instruct-AWQ
```
Routing modes: `roundrobin` (demo visibility) · `session` (sticky per session-id) ·
`prefixaware`/`kvaware` (route to the backend most likely to already hold the prompt's KV cache —
the one-sentence answer: *"send a request to the replica that has already computed that prefix,
so you reuse KV cache instead of recomputing it"*).

## Deploy
```bash
# 1. 2nd GPU node (eks.tf: gpu desired_size=2)
cd ../vllm-serving-eks/terraform && terraform apply

# 2. Retire Project 1's standalone deployment — REQUIRED: its Service is named `vllm`, which
#    injects VLLM_PORT=tcp://... into every pod in the namespace and crashes new engines.
kubectl delete deployment vllm && kubectl delete service vllm

# 3. Install the production-stack
helm repo add vllm https://vllm-project.github.io/production-stack && helm repo update
helm install vllm vllm/vllm-stack -f ../vllm-multimodel-routing/values.yaml

# 4. Verify (port-forwards the router, curls both models, shows routing logs)
bash scripts/verify-routing.sh
```

## How values.yaml gets applied
`helm install vllm vllm/vllm-stack -f values.yaml` works in three steps:
1. Helm downloads the **chart** (a bundle of *templated* Kubernetes manifests) from the repo.
2. It **renders** those templates by filling in our `values.yaml` overrides on top of the chart's
   defaults — e.g. each `modelSpec` entry becomes a full Deployment + Service manifest with our
   image tag, GPU request, and vLLM flags substituted in.
3. It applies the rendered manifests to the cluster and records them as a **release** named
   `vllm` (revision 1). Changing `values.yaml` later and running
   `helm upgrade vllm vllm/vllm-stack -f values.yaml` re-renders and applies only the diff —
   that's the model-swap/rollout path (and `helm rollback vllm 1` reverts a bad change).

## Notes / deliberate choices
- Both models **ungated** → no HF token anywhere.
- **No PVCs** (`pvcStorage` omitted): cluster has no EBS CSI driver; weights re-download on pod
  start, which is fine for a demo and avoids a new failure mode.
- Engine image pinned `vllm/vllm-openai:v0.22.1` (Row 1 known-good), not `:latest`.
- `runtimeClassName: nvidia` — exists because the GPU Operator created it (verified in-cluster).
- Cost while both GPUs run: **~$1.85/hr** → scale GPU node group to 0 when done.
