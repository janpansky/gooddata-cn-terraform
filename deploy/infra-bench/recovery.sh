#!/usr/bin/env bash
set -euo pipefail
###
# Recovery-after-kill benchmark: how fast a server comes back after its pod is
# killed (crash / OOM-kill / node drain) WITHOUT touching the node. The controller
# reschedules a new pod on the same warm GPU node; the model reloads from cache.
# This is the resilience metric cold-start (scale 0->1) does NOT capture — here the
# node stays, only the process dies.
#
# Emits JSON: kill_to_ready_s, ready_to_first_s, kill_to_serving_s (total downtime).
#
# Usage: ./recovery.sh <vllm|sglang|sie> [max_tokens]
###
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SERVER="${1:-}"; MAX_TOKENS="${2:-64}"

# workload | ns | svc | port | model  (mirror of use-server.sh registry)
case "$SERVER" in
  vllm)   KIND=deployment;  NAME=vllm;                  NS=inference; SVC=vllm;        PORT=8000; MODEL="Qwen/Qwen3.6-27B" ;;
  sglang) KIND=deployment;  NAME=sglang;                NS=inference; SVC=sglang;      PORT=8000; MODEL="Qwen/Qwen3.6-27B" ;;
  # SIE worker is a StatefulSet; the exact name depends on the GPU profile the
  # helm release installed (e.g. sie-worker-l4-sglang / sie-worker-h100-sglang).
  # Override with SIE_WORKLOAD if the installed name differs.
  sie)    KIND=statefulset; NAME="${SIE_WORKLOAD:-sie-worker-h100-sglang}"; NS=sie; SVC=sie-gateway; PORT=8080; MODEL="${SIE_MODEL:-Qwen/Qwen3.6-27B:h100}" ;;
  *) echo "Usage: ./recovery.sh <vllm|sglang|sie> [max_tokens]"; exit 1 ;;
esac
READY_TIMEOUT="${READY_TIMEOUT:-1800s}"
LOCAL_PORT="${LOCAL_PORT:-18010}"
now() { python3 -c 'import time;print(f"{time.time():.3f}")'; }

# must be Ready to start (this is recovery, not cold start)
rr=$(kubectl -n "$NS" get "$KIND" "$NAME" -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo 0)
[ "${rr:-0}" -ge 1 ] || { echo "ERROR: $KIND/$NAME not Ready (readyReplicas=$rr) — bring it up before a recovery test"; exit 2; }

POD=$(kubectl -n "$NS" get pods -l "app=$NAME" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
[ -z "$POD" ] && POD=$(kubectl -n "$NS" get pods -o name 2>/dev/null | grep "$NAME" | head -1 | cut -d/ -f2)
echo ">> [$SERVER] killing pod $POD — node stays, process dies"

T0=$(now)
kubectl -n "$NS" delete pod "$POD" --wait=false >/dev/null
if ! kubectl -n "$NS" rollout status "$KIND/$NAME" --timeout="$READY_TIMEOUT" >/dev/null 2>&1; then
  echo "{\"test\":\"recovery-after-kill\",\"server\":\"$SERVER\",\"error\":\"did not recover within $READY_TIMEOUT\"}"; exit 2
fi
T_READY=$(now)

kubectl -n "$NS" port-forward "svc/$SVC" "$LOCAL_PORT:$PORT" >/dev/null 2>&1 &
PF_PID=$!; trap 'kill $PF_PID 2>/dev/null || true' EXIT
for _ in $(seq 1 30); do
  python3 -c "import socket,sys; s=socket.socket(); s.settimeout(1); sys.exit(0 if s.connect_ex(('127.0.0.1',$LOCAL_PORT))==0 else 1)" 2>/dev/null && break
  sleep 1
done

FIRST_JSON=$(python3 "$SCRIPT_DIR/loadtest.py" --base-url "http://localhost:$LOCAL_PORT/v1" \
  --model "$MODEL" --concurrency 1 --requests 1 --max-tokens "$MAX_TOKENS" --disable-thinking --json 2>/dev/null || echo '{}')
T_FIRST=$(now)

python3 - "$SERVER" "$MODEL" "$T0" "$T_READY" "$T_FIRST" "$FIRST_JSON" <<'PY'
import json, sys
s, model, t0, tready, tfirst, fj = sys.argv[1:7]
t0, tready, tfirst = float(t0), float(tready), float(tfirst)
try: ttft = json.loads(fj).get("ttft_p50_s")
except Exception: ttft = None
print(json.dumps({
  "test": "recovery-after-kill", "server": s, "model": model,
  "kill_to_ready_s": round(tready - t0, 1),
  "ready_to_first_s": round(tfirst - tready, 1),
  "kill_to_serving_s": round(tfirst - t0, 1),
  "first_request_ttft_s": ttft,
}))
PY
