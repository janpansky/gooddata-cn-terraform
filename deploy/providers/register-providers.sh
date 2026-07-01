#!/usr/bin/env bash
set -euo pipefail

###
# Register all 6 LLM providers in the local-inference GoodData CN org.
# Each is type LOCAL (OpenAI-compatible Chat Completions).
#
# Reads config from providers.env next to this script (gitignored).
# Copy providers.env.example → providers.env and fill in secrets.
#
# Provider map:
#   local-vllm-qwen27b   → vLLM,         Qwen3.6-27B FP8       (GPU 0)
#   local-sie-llama70b   → SIE gateway,  Llama-3.3-70B AWQ     (GPU 1)
#   local-sie-qwen14b    → SIE gateway,  Qwen3-14B BF16        (GPU 2)
#   local-sie-qwen4b     → SIE gateway,  Qwen3-4B-Instruct-2507 (GPU 2, LRU)
#   local-sie-qwen35     → SIE gateway,  Qwen3.5-4B            (GPU 2, LRU)
#   local-sie-gemma26b   → SIE gateway,  Gemma-4-26B-A4B FP8  (GPU 3)
#
# Only one provider is "active" for gen-ai at a time — switch between them
# by changing the org-level default LLM provider in GoodData Settings.
# Re-running is idempotent (delete + create per provider).
###

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="$SCRIPT_DIR/providers.env"

if [[ ! -f "$ENV_FILE" ]]; then
    echo "ERROR: $ENV_FILE not found."
    echo "       cp $SCRIPT_DIR/providers.env.example $ENV_FILE  # then fill in secrets"
    exit 1
fi
# shellcheck source=/dev/null
source "$ENV_FILE"

: "${TIGER_ENDPOINT:?Set TIGER_ENDPOINT in providers.env}"
: "${TIGER_API_TOKEN:?Set TIGER_API_TOKEN in providers.env}"

register() {
    local id="$1" name="$2" base_url="$3" api_key="$4" model="$5"

    echo ">> Registering '$id'  (model: $model)"
    curl -sf -o /dev/null -w "   delete old: %{http_code}\n" \
        -H "Authorization: Bearer $TIGER_API_TOKEN" \
        -H "Content-Type: application/vnd.gooddata.api+json" \
        -X DELETE \
        "$TIGER_ENDPOINT/api/v1/entities/llmProviders/$id" || true

    curl -sf \
        -H "Authorization: Bearer $TIGER_API_TOKEN" \
        -H "Content-Type: application/vnd.gooddata.api+json" \
        -X POST \
        -d "{
          \"data\": {
            \"id\": \"$id\",
            \"type\": \"llmProvider\",
            \"attributes\": {
              \"name\": \"$name\",
              \"description\": \"OpenAI-compatible Chat Completions — local inference\",
              \"defaultModelId\": \"$model\",
              \"providerConfig\": {
                \"type\": \"OPENAI\",
                \"baseUrl\": \"$base_url\",
                \"auth\": {
                  \"type\": \"API_KEY\",
                  \"apiKey\": \"$api_key\"
                }
              },
              \"models\": [{
                \"family\": \"UNKNOWN\",
                \"id\": \"$model\"
              }]
            }
          }
        }" \
        "$TIGER_ENDPOINT/api/v1/entities/llmProviders" > /dev/null
    echo "   OK"
}

# --- vLLM: Qwen3.6-27B FP8 (GPU 0) ---
if [[ "${REGISTER_VLLM:-true}" == "true" ]]; then
    register "local-vllm-qwen27b" "vLLM · Qwen3.6-27B FP8" \
        "${VLLM_BASE_URL:-http://vllm.inference.svc.cluster.local:8000/v1}" \
        "${VLLM_API_KEY:-local}" \
        "${VLLM_MODEL:-Qwen/Qwen3.6-27B}"
fi

# --- SIE: Llama-3.3-70B AWQ (GPU 1) ---
if [[ "${REGISTER_SIE_LLAMA:-true}" == "true" ]]; then
    register "local-sie-llama70b" "SIE · Llama-3.3-70B AWQ" \
        "${SIE_BASE_URL:-http://sie-gateway.sie.svc.cluster.local:8080/v1}" \
        "${SIE_API_KEY:-local}" \
        "${SIE_MODEL_LLAMA:-meta-llama/Llama-3.3-70B-Instruct}"
fi

# --- SIE: Qwen3-14B BF16 (GPU 2) ---
if [[ "${REGISTER_SIE_QWEN14B:-true}" == "true" ]]; then
    register "local-sie-qwen14b" "SIE · Qwen3-14B" \
        "${SIE_BASE_URL:-http://sie-gateway.sie.svc.cluster.local:8080/v1}" \
        "${SIE_API_KEY:-local}" \
        "${SIE_MODEL_QWEN14B:-Qwen/Qwen3-14B}"
fi

# --- SIE: Qwen3-4B-Instruct-2507 (GPU 2, LRU) ---
if [[ "${REGISTER_SIE_QWEN4B:-true}" == "true" ]]; then
    register "local-sie-qwen4b" "SIE · Qwen3-4B-Instruct-2507" \
        "${SIE_BASE_URL:-http://sie-gateway.sie.svc.cluster.local:8080/v1}" \
        "${SIE_API_KEY:-local}" \
        "${SIE_MODEL_QWEN4B:-Qwen/Qwen3-4B-Instruct-2507}"
fi

# --- SIE: Qwen3.5-4B (GPU 2, LRU) ---
if [[ "${REGISTER_SIE_QWEN35:-true}" == "true" ]]; then
    register "local-sie-qwen35" "SIE · Qwen3.5-4B" \
        "${SIE_BASE_URL:-http://sie-gateway.sie.svc.cluster.local:8080/v1}" \
        "${SIE_API_KEY:-local}" \
        "${SIE_MODEL_QWEN35:-Qwen/Qwen3.5-4B}"
fi

# --- SIE: Gemma-4-26B-A4B FP8 (GPU 3) ---
if [[ "${REGISTER_SIE_GEMMA:-true}" == "true" ]]; then
    register "local-sie-gemma26b" "SIE · Gemma-4-26B-A4B FP8" \
        "${SIE_BASE_URL:-http://sie-gateway.sie.svc.cluster.local:8080/v1}" \
        "${SIE_API_KEY:-local}" \
        "${SIE_MODEL_GEMMA:-google/gemma-4-26B-A4B-it}"
fi

echo ""
echo "Registered providers:"
curl -s -H "Authorization: Bearer $TIGER_API_TOKEN" \
    "$TIGER_ENDPOINT/api/v1/entities/llmProviders" \
    | python3 -c "import json,sys; [print('  -', p['id']) for p in json.load(sys.stdin)['data']]" \
    2>/dev/null || echo "  (listing failed — check TIGER_API_TOKEN)"
