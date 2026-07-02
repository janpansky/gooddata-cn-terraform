#!/usr/bin/env bash
set -uo pipefail
###
# Benchmark SIE on the Superlinked MANAGED endpoint (their GPU, their SIE service).
# Unblocks the SIE-on-27B question WITHOUT our own 80GB GPU — the model there is
# Qwen/Qwen3.6-27B FP8. Runs the same metric suite as our in-cluster bench, but
# from the laptop against their external endpoint.
#
# Usage:  SIE_API_KEY=SL-xxxxx ./sie-endpoint-bench.sh
# Env:    SIE_BASE_URL (default = the managed cluster in providers.env.example),
#         CONC (default "1 4 8 16"), REQS_PER_C (10), MAX_TOKENS (128), INPUT_TOKENS (2048)
#
# CAVEAT: this is SIE on Superlinked's hardware — NOT apples-to-apples with our
# vLLM-on-L40S numbers. It answers "does SIE handle 27B well" (latency/stability/
# tools/context), not "SIE vs vLLM on the same card". Label results accordingly.
###
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
URL="${SIE_BASE_URL:-http://a64e1dc31032c40e4b1e9330a1273c83-1760332796.us-east-2.elb.amazonaws.com:8080/v1}"
KEY="${SIE_API_KEY:-}"
MODEL="${SIE_MODEL:-Qwen/Qwen3.6-27B}"
CONC="${CONC:-1 4 8 16}"
REQS_PER_C="${REQS_PER_C:-10}"
MAX_TOKENS="${MAX_TOKENS:-128}"
INPUT_TOKENS="${INPUT_TOKENS:-2048}"
OUT="$SCRIPT_DIR/results-27b-sie-endpoint.md"

[ -z "$KEY" ] && { echo "ERROR: set SIE_API_KEY=SL-... (token from Superlinked)"; exit 1; }

echo ">> SIE managed endpoint: $URL  model=$MODEL"
echo ">> liveness check..."
code=$(curl -s -o /dev/null -w "%{http_code}" --max-time 15 -H "Authorization: Bearer $KEY" "$URL/models" 2>/dev/null)
echo "   /models -> HTTP $code"
[ "$code" = "200" ] || echo "   WARN: not 200 — token wrong / model not loaded / endpoint down. Continuing anyway."

: > "$OUT"
{
  echo "# SIE on Superlinked managed endpoint — Qwen3.6-27B"
  echo ""
  echo "SIE serving the production 27B on **Superlinked's hardware** (their managed cluster)."
  echo "NOT same-hardware vs our vLLM-on-L40S — this answers 'does SIE handle 27B well'."
  echo "Endpoint: $URL"
  echo ""
  echo '## Warm latency + throughput + stability (thinking-off, input≈'"$INPUT_TOKENS"')'
  echo '```'
} >> "$OUT"

for c in $CONC; do
  echo ">> concurrency $c ..."
  python3 "$SCRIPT_DIR/loadtest.py" --base-url "$URL" --model "$MODEL" --api-key "$KEY" \
    --concurrency "$c" --requests "$(( c * REQS_PER_C ))" --warmup 3 \
    --max-tokens "$MAX_TOKENS" --input-tokens "$INPUT_TOKENS" --disable-thinking --json 2>&1 \
    | grep -E '\{"model"' >> "$OUT" || echo "  (c=$c failed)" >> "$OUT"
done
echo '```' >> "$OUT"

# function-calling probe (agentic prerequisite)
echo ">> function-calling probe ..."
{
  echo ""
  echo "## function-calling probe"
  echo '```'
  curl -s --max-time 60 "$URL/chat/completions" -H "Authorization: Bearer $KEY" -H "Content-Type: application/json" \
    -d "{\"model\":\"$MODEL\",\"messages\":[{\"role\":\"user\",\"content\":\"Weather in Prague? Use the tool.\"}],\"tools\":[{\"type\":\"function\",\"function\":{\"name\":\"get_weather\",\"description\":\"Get weather\",\"parameters\":{\"type\":\"object\",\"properties\":{\"city\":{\"type\":\"string\"}},\"required\":[\"city\"]}}}],\"tool_choice\":\"auto\",\"max_tokens\":256}" \
    | python3 -c "import json,sys; d=json.load(sys.stdin); tc=d['choices'][0]['message'].get('tool_calls'); print('tool_calls:', [(t['function']['name'],t['function']['arguments']) for t in tc] if tc else 'NONE'); print('finish:', d['choices'][0].get('finish_reason'))" 2>/dev/null || echo "(probe failed)"
  echo '```'
} >> "$OUT"

echo ""
echo "=== DONE — $OUT ==="
cat "$OUT"
