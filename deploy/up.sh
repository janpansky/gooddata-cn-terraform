#!/usr/bin/env bash
set -euo pipefail

###
# Bring up the full 6-model inference stack on a g6e.12xlarge (4x L40S 48 GB).
#
# GPU layout:
#   GPU 0 — vLLM:     Qwen3.6-27B FP8          http://vllm.inference.svc.cluster.local:8000/v1
#   GPU 1 — SIE[0]:   Llama-3.3-70B AWQ-INT4   \
#   GPU 2 — SIE[1]:   Qwen3-14B + 4B LRU        > http://sie-gateway.sie.svc.cluster.local:8080/v1
#   GPU 3 — SIE[2]:   Gemma-4-26B-A4B FP8      /
#
# Prerequisites:
#   1. kubectl context set to local-inference (./deploy.sh local-inference kubectl)
#   2. Terraform applied with g6e.12xlarge (envs/local-inference/settings.tfvars)
#   3. providers/providers.env exists with TIGER_API_TOKEN and HF_TOKEN
#
# Model cold start times (from S3 cache; ~3x longer from HuggingFace):
#   Qwen3.6-27B FP8    ~5 min   (vLLM, FP8 quantize)
#   Llama-3.3-70B AWQ  ~8 min   (first request triggers SIE load)
#   Qwen3-14B          ~4 min   (first request triggers SIE load)
#   4B models          ~2 min   (first request triggers SIE load)
#   Gemma-4-26B FP8    ~6 min   (first request triggers SIE load + FP8 quantize)
###

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="$SCRIPT_DIR/providers/providers.env"

# ---------------------------------------------------------------------------
# 0. Pre-flight checks
# ---------------------------------------------------------------------------
if [[ ! -f "$ENV_FILE" ]]; then
    echo "ERROR: providers/providers.env not found."
    echo "  cp $SCRIPT_DIR/providers/providers.env.example $ENV_FILE"
    echo "  # fill in TIGER_API_TOKEN and HF_TOKEN, then re-run"
    exit 1
fi

echo ">> Checking kubectl context..."
if ! kubectl cluster-info --request-timeout=5s >/dev/null 2>&1; then
    echo "ERROR: kubectl cannot reach the cluster."
    echo "  Run: ./deploy.sh local-inference kubectl   (from the gooddata-cn-terraform root)"
    exit 1
fi

# ---------------------------------------------------------------------------
# 1. vLLM — Qwen3.6-27B FP8 on GPU 0
# ---------------------------------------------------------------------------
echo ""
echo ">> [1/3] Applying vLLM (Qwen3.6-27B FP8, GPU 0)..."
kubectl apply -f "$SCRIPT_DIR/k8s/vllm-cache-pvc.yaml"
kubectl apply -f "$SCRIPT_DIR/k8s/vllm-qwen.yaml"
kubectl -n inference scale deploy/vllm --replicas=1
echo "   vLLM pod requested — model load starts when GPU node is ready."

# ---------------------------------------------------------------------------
# 2. SIE — 3 sglang workers (Llama GPU 1, Qwen14B+LRU GPU 2, Gemma GPU 3)
# ---------------------------------------------------------------------------
echo ""
echo ">> [2/3] Installing/upgrading SIE (Llama-70B | Qwen14B+LRU | Gemma-26B)..."
"$SCRIPT_DIR/helm/install-sie.sh"

# ---------------------------------------------------------------------------
# 3. Register providers in GoodData CN
# ---------------------------------------------------------------------------
echo ""
echo ">> [3/3] Registering LLM providers in GoodData CN..."
"$SCRIPT_DIR/providers/register-providers.sh"

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
cat <<'EOF'

=====================================================================
  Inference stack is coming up. GPU node may take ~5 min to join.
  Model loads start on first request (sticky routing per worker).
=====================================================================

  Endpoints (in-cluster):
    vLLM (Qwen3.6-27B):   http://vllm.inference.svc.cluster.local:8000/v1
    SIE gateway (all 5):  http://sie-gateway.sie.svc.cluster.local:8080/v1

  Port-forward for quick smoke tests:
    kubectl -n inference port-forward svc/vllm 8000:8000 &
    kubectl -n sie      port-forward svc/sie-gateway 8080:8080 &

  Check status:          ./status.sh
  Scale down (save $):   ./down.sh
EOF
