#!/usr/bin/env bash
set -euo pipefail
###
# Credible warm benchmark: runs loadtest.py as a Job INSIDE the cluster, hitting
# the server's Service directly (.svc.cluster.local) — no kubectl port-forward,
# so latency is server-side, not laptop->cluster RTT. Warmup discard + large
# sample + concurrency sweep.
#
# Usage: ./incluster-bench.sh <vllm|sie|sglang> [model-override]
# Env:   CONCURRENCIES (default "1 4 8 16"), REQS_PER_C (default 25), WARMUP (5)
#
# Same model on every server = apples-to-apples serving comparison. Override the
# model to force one that fits all (e.g. Qwen3-4B), since 27B only fits vLLM.
###
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SERVER="${1:-}"; MODEL_OVERRIDE="${2:-}"
CONCURRENCIES="${CONCURRENCIES:-1 4 8 16}"
REQS_PER_C="${REQS_PER_C:-25}"
WARMUP="${WARMUP:-5}"
MAX_TOKENS="${MAX_TOKENS:-128}"
INPUT_TOKENS="${INPUT_TOKENS:-0}"
BENCH_NS="${BENCH_NS:-default}"
# DISABLE_THINKING=1 -> pass --disable-thinking (prod-realistic for Qwen3; clean TTFT)
THINK_FLAG=""; [ "${DISABLE_THINKING:-0}" = "1" ] && THINK_FLAG="--disable-thinking"
JOB_TIMEOUT="${JOB_TIMEOUT:-1800}"

case "$SERVER" in
  vllm)   URL="http://vllm.inference.svc.cluster.local:8000/v1";   MODEL="Qwen/Qwen3.6-27B" ;;
  sglang) URL="http://sglang.inference.svc.cluster.local:8000/v1"; MODEL="Qwen/Qwen3-4B-Instruct-2507" ;;
  sie)    URL="http://sie-gateway.sie.svc.cluster.local:8080/v1";  MODEL="Qwen/Qwen3-4B-Instruct-2507" ;;
  *) echo "Usage: ./incluster-bench.sh <vllm|sie|sglang> [model-override]"; exit 1 ;;
esac
[ -n "$MODEL_OVERRIDE" ] && MODEL="$MODEL_OVERRIDE"
JOB="bench-$SERVER"

echo ">> in-cluster benchmark: $SERVER  model=$MODEL  url=$URL"
echo "   concurrency=[$CONCURRENCIES] reqs/c=$REQS_PER_C warmup=$WARMUP"

# clean previous
kubectl -n "$BENCH_NS" delete job "$JOB" --ignore-not-found >/dev/null 2>&1 || true
kubectl -n "$BENCH_NS" delete configmap "$JOB-script" --ignore-not-found >/dev/null 2>&1 || true
kubectl -n "$BENCH_NS" create configmap "$JOB-script" --from-file=loadtest.py="$SCRIPT_DIR/loadtest.py" >/dev/null

# build the in-pod sweep command
SWEEP=""
for c in $CONCURRENCIES; do
  SWEEP="$SWEEP python3 /bench/loadtest.py --base-url '$URL' --model '$MODEL' --concurrency $c --requests \$(( $c * $REQS_PER_C )) --warmup $WARMUP --max-tokens $MAX_TOKENS --input-tokens $INPUT_TOKENS $THINK_FLAG --json;"
done

cat <<YAML | kubectl -n "$BENCH_NS" apply -f - >/dev/null
apiVersion: batch/v1
kind: Job
metadata:
  name: $JOB
spec:
  backoffLimit: 0
  ttlSecondsAfterFinished: 600
  template:
    spec:
      restartPolicy: Never
      containers:
        - name: bench
          image: python:3.12-slim
          command: ["bash","-c","$SWEEP"]
          volumeMounts:
            - name: script
              mountPath: /bench
      volumes:
        - name: script
          configMap:
            name: $JOB-script
YAML

echo ">> waiting for benchmark Job to finish (timeout ${JOB_TIMEOUT}s)..."
kubectl -n "$BENCH_NS" wait --for=condition=complete "job/$JOB" --timeout="${JOB_TIMEOUT}s" 2>/dev/null \
  || { echo "Job did not complete; logs:"; kubectl -n "$BENCH_NS" logs "job/$JOB" 2>/dev/null | tail -20; exit 2; }

echo "=== RESULTS ($SERVER, $MODEL) ==="
kubectl -n "$BENCH_NS" logs "job/$JOB" 2>/dev/null
kubectl -n "$BENCH_NS" delete job "$JOB" --ignore-not-found >/dev/null 2>&1 || true
kubectl -n "$BENCH_NS" delete configmap "$JOB-script" --ignore-not-found >/dev/null 2>&1 || true
