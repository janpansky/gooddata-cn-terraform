#!/usr/bin/env bash
set -euo pipefail

###
# Show the current state of the inference stack:
#   - GPU node presence and GPU allocation
#   - vLLM pod (GPU 0, inference namespace)
#   - SIE pods (GPUs 1-3, sie namespace)
#   - Loaded models via SIE gateway (if reachable via port-forward)
#   - Registered LLM providers in GoodData CN
###

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="$SCRIPT_DIR/providers/providers.env"

echo "=== GPU nodes ==="
GPU_NODES=$(kubectl get nodes -l workload=inference --no-headers 2>/dev/null | wc -l | tr -d ' ')
if [[ "$GPU_NODES" -eq 0 ]]; then
    echo "  (none — GPU node not running; run ./up.sh to start)"
else
    kubectl get nodes -l workload=inference \
        -o custom-columns="NODE:.metadata.name,STATUS:.status.conditions[-1].type,GPU:.status.allocatable.nvidia\.com/gpu" \
        2>/dev/null
fi

echo ""
echo "=== vLLM pod (inference namespace) ==="
kubectl -n inference get pods -l app=vllm \
    -o custom-columns="POD:.metadata.name,STATUS:.status.phase,READY:.status.containerStatuses[0].ready" \
    2>/dev/null || echo "  (none)"

echo ""
echo "=== SIE pods (sie namespace) ==="
kubectl -n sie get pods \
    -o custom-columns="POD:.metadata.name,STATUS:.status.phase,READY:.status.containerStatuses[0].ready" \
    2>/dev/null || echo "  (none)"

echo ""
echo "=== SIE models (via port-forward on :8080) ==="
if curl -sf --max-time 2 http://localhost:8080/v1/models >/dev/null 2>&1; then
    curl -s http://localhost:8080/v1/models \
        | python3 -c "import json,sys;[print('  -',m['id']) for m in json.load(sys.stdin)['data']]" \
        2>/dev/null || echo "  (parse error)"
else
    echo "  (not reachable — run: kubectl -n sie port-forward svc/sie-gateway 8080:8080 &)"
fi

echo ""
echo "=== vLLM models (via port-forward on :8000) ==="
if curl -sf --max-time 2 http://localhost:8000/v1/models >/dev/null 2>&1; then
    curl -s http://localhost:8000/v1/models \
        | python3 -c "import json,sys;[print('  -',m['id']) for m in json.load(sys.stdin)['data']]" \
        2>/dev/null || echo "  (parse error)"
else
    echo "  (not reachable — run: kubectl -n inference port-forward svc/vllm 8000:8000 &)"
fi

echo ""
echo "=== Registered LLM providers in GoodData CN ==="
if [[ -f "$ENV_FILE" ]]; then
    # shellcheck source=/dev/null
    source "$ENV_FILE"
    TIGER_ENDPOINT="${TIGER_ENDPOINT:-}"
    TIGER_API_TOKEN="${TIGER_API_TOKEN:-}"
    if [[ -n "$TIGER_ENDPOINT" && -n "$TIGER_API_TOKEN" ]]; then
        curl -s --max-time 5 \
            -H "Authorization: Bearer $TIGER_API_TOKEN" \
            "$TIGER_ENDPOINT/api/v1/entities/llmProviders" \
            | python3 -c "
import json, sys
data = json.load(sys.stdin).get('data', [])
for p in data:
    a = p.get('attributes', {})
    cfg = a.get('providerConfig', {})
    print(f'  {p[\"id\"]:30s}  {a.get(\"defaultModelId\",\"?\")}')
" 2>/dev/null || echo "  (API call failed — check TIGER_API_TOKEN)"
    else
        echo "  (providers.env missing TIGER_ENDPOINT or TIGER_API_TOKEN)"
    fi
else
    echo "  (providers.env not found)"
fi

echo ""
echo "=== Expected endpoints (in-cluster) ==="
echo "  vLLM (Qwen3.6-27B):   http://vllm.inference.svc.cluster.local:8000/v1"
echo "  SIE (all 5 models):    http://sie-gateway.sie.svc.cluster.local:8080/v1"
echo ""
echo "  Models on SIE gateway:"
echo "    GPU 1 — meta-llama/Llama-3.3-70B-Instruct   (AWQ-INT4, sticky)"
echo "    GPU 2 — Qwen/Qwen3-14B                      (BF16, sticky)"
echo "    GPU 2 — Qwen/Qwen3-4B-Instruct-2507         (LRU with Qwen3.5-4B)"
echo "    GPU 2 — Qwen/Qwen3.5-4B                     (LRU with Qwen3-4B-2507)"
echo "    GPU 3 — google/gemma-4-26B-A4B-it           (FP8, sticky)"
