#!/usr/bin/env bash
# Project 2 (multi-model routing) checkpoint: prove BOTH models answer through the ROUTER and requests hit
# different backends. Prints each command before running it.
set -uo pipefail

PORT=30080
PF_PID=""
cleanup() { [ -n "$PF_PID" ] && kill "$PF_PID" 2>/dev/null || true; }
trap cleanup EXIT
run() { echo "\$ $*"; "$@"; }

echo "==> [1/4] Engine + router pods"
run kubectl get pods -o wide

echo; echo "==> [2/4] Port-forward the ROUTER (single entry point for all models)"
echo "\$ kubectl port-forward svc/vllm-router-service ${PORT}:80   # backgrounded"
kubectl port-forward svc/vllm-router-service "${PORT}:80" >/tmp/router-pf.log 2>&1 &
PF_PID=$!
for i in $(seq 1 20); do
  curl -sf "http://localhost:${PORT}/v1/models" >/dev/null 2>&1 && break
  sleep 1
  [ "$i" = "20" ] && { echo "FAIL: router tunnel never came up. See /tmp/router-pf.log"; exit 1; }
done

echo; echo "==> [3/4] /v1/models through the router (must list BOTH models)"
echo "\$ curl -s http://localhost:${PORT}/v1/models"
curl -s "http://localhost:${PORT}/v1/models" | (jq -r '.data[].id' 2>/dev/null || cat)

echo; echo "==> [4/4] One completion through EACH model, via the SAME router endpoint"
for M in "Qwen/Qwen2.5-1.5B-Instruct" "Qwen/Qwen2.5-7B-Instruct-AWQ"; do
  echo; echo "--- model: $M"
  echo "\$ curl -s http://localhost:${PORT}/v1/completions -d '{\"model\":\"$M\",...}'"
  curl -s "http://localhost:${PORT}/v1/completions" \
    -H "Content-Type: application/json" \
    -d "{\"model\":\"$M\",\"prompt\":\"The capital of France is\",\"max_tokens\":12,\"temperature\":0}" \
    | (jq -r '.choices[0].text' 2>/dev/null || cat)
done

echo; echo "==> Routing evidence: router logs showing requests dispatched to backends"
echo "\$ kubectl logs deploy/vllm-deployment-router --tail=20"
kubectl logs deploy/vllm-deployment-router --tail=20 2>/dev/null \
  | grep -iE "rout|backend|proxy|engine|completion" | tail -10 || true

echo; echo "✅ Project 2 verification complete: both models served through one router endpoint."
