#!/usr/bin/env bash
set -uo pipefail   # deliberately NOT -e: one failing phase must not abort the whole
                   # day — H100 time is prepaid, so we collect partial results.
###
# H100 DAY — full serving-layer benchmark matrix for Qwen3.6-27B on a single
# H100 80GB (p5.4xlarge, EC2 Capacity Block). The point: get SIE numbers on the
# 27B (impossible on our 48GB L40S), with vLLM as the baseline.
#
# ONE command. When the reserved H100 node is up in jan-inference, run:
#     ./h100-day.sh
# It executes every metric group, writes results-27b-h100.md, and ALWAYS scales
# the GPU workloads to 0 on exit (trap) — a hung step never burns idle H100 time.
#
# Metric groups (Jan's plan):
#   Cold start  : provision_ready, first_request_warmup, cold_full, new_conversation_cold (SIE)
#   Warm latency: TTFT, TPOT, e2e p50/p95/p99
#   Throughput  : tokens/s, req/s, saturation_concurrency
#   Scaling     : scale_up_time (=provision_ready), scale_to_zero_time
#   Stability   : error_rate, recovery_time, GPU util / VRAM
#   + hard reqs : 32K context, function-calling (agentic prerequisite)
#
# ISOLATION + BUDGET guards (refuse to run if any fails):
#   - kubectl context must be jan-inference (never touch the shared cluster)
#   - GPU nodegroup instance type must be H100 (p5*)  [FORCE=1 to override]
#   - GPU nodegroup max size must be 1 (never a 2nd H100)
#   - trap: scale vllm + sglang + SIE workers to 0 on ANY exit
###
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUT="$SCRIPT_DIR/results-27b-h100.md"
SERVERS="${SERVERS:-vllm sie sglang}"   # full 3-way head-to-head on 27B (all fit on 80GB)
CONC="${CONC:-1 4 8 16 32}"
REQS_PER_C="${REQS_PER_C:-15}"
INPUT_TOKENS="${INPUT_TOKENS:-2048}"
MODEL="Qwen/Qwen3.6-27B"
DEPLOY_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)/deploy"
log(){ echo ">> $*"; }
w(){ echo "$*" >> "$OUT"; }

# ---------- guards ----------
CTX="$(kubectl config current-context 2>/dev/null)"
case "$CTX" in *jan-inference*) ;; *) echo "ABORT: context '$CTX' != jan-inference (isolation guard)"; exit 1;; esac
GPU_INST="$(kubectl get nodes -l workload=inference -o jsonpath='{.items[0].metadata.labels.node\.kubernetes\.io/instance-type}' 2>/dev/null)"
if [[ "$GPU_INST" != p5* && "${FORCE:-0}" != 1 ]]; then
  echo "ABORT: GPU node instance-type is '${GPU_INST:-none}', expected H100 (p5*)."
  echo "       Bring up the p5.4xlarge (Capacity Block) first, or FORCE=1 to override."; exit 1
fi
log "context=$CTX  gpu=$GPU_INST  servers=[$SERVERS]"

# ---------- budget-safety teardown ----------
teardown(){
  log "TEARDOWN — scaling GPU workloads to 0 (budget safety)"
  kubectl -n inference scale deploy/vllm   --replicas=0 >/dev/null 2>&1 || true
  kubectl -n inference scale deploy/sglang --replicas=0 >/dev/null 2>&1 || true
  kubectl -n sie get statefulset -o name 2>/dev/null | xargs -r -n1 kubectl -n sie scale --replicas=0 >/dev/null 2>&1 || true
}
trap teardown EXIT INT TERM

# ---------- results header ----------
: > "$OUT"
w "# Serving benchmark — Qwen3.6-27B on 1× H100 80GB (p5.4xlarge, Capacity Block)"
w ""
w "The SIE-on-27B run our L40S could not do (OOM at 48GB). vLLM = baseline. Method:"
w "in-cluster load, warmup discarded, concurrency sweep [$CONC], input=${INPUT_TOKENS}tok."
w "Isolated env: jan-inference. Instance: $GPU_INST."
w ""

# ---------- per-server matrix ----------
run_server(){
  local S="$1"
  log "===== $S ====="
  w "## $S"
  w '```'

  # switch the single GPU to this server (scales others to 0, brings this up)
  ( cd "$DEPLOY_DIR/inference" && ./use-server.sh "$S" ) >/dev/null 2>&1 || log "WARN: use-server.sh $S returned nonzero"

  # 1) COLD START + scale_up_time (coldstart.sh scales 0->1, times readiness+first req)
  log "[$S] cold start"
  w "-- cold start (provision_ready = scale_up_time, first_request_warmup, cold_full) --"
  ( "$SCRIPT_DIR/coldstart.sh" "$S" 64 2>&1 | grep -E '\{|_s' ) >> "$OUT" 2>&1 || w "  (cold start failed)"

  # 2) WARM latency + throughput + error_rate (sweep). saturation_concurrency = where
  #    tok/s plateaus or errors appear — read from the sweep rows.
  log "[$S] warm sweep"
  w "-- warm latency + throughput + stability (per concurrency) --"
  ( DISABLE_THINKING=1 CONCURRENCIES="$CONC" REQS_PER_C="$REQS_PER_C" WARMUP=5 \
      INPUT_TOKENS="$INPUT_TOKENS" JOB_TIMEOUT=2400 \
      "$SCRIPT_DIR/incluster-bench.sh" "$S" 2>&1 | grep -E '\{"model"' ) >> "$OUT" 2>&1 || w "  (sweep failed)"

  # 3) GPU util / VRAM while resident
  log "[$S] gpu snapshot"
  w "-- GPU util / VRAM (resident) --"
  ( LABEL="$S-resident" "$SCRIPT_DIR/gpu-snapshot.sh" ) >> "$OUT" 2>&1 || w "  (snapshot failed)"

  # 4) HARD REQ: 32K context (agentic/RAG needs >=32K; SIE historically capped at 4K)
  log "[$S] 32K context probe"
  w "-- 32K context probe --"
  probe_context "$S" >> "$OUT" 2>&1 || w "  (context probe failed)"

  # 5) HARD REQ: function-calling (agentic prerequisite; SIE had a tools blocker)
  log "[$S] function-calling probe"
  w "-- function-calling probe (does it emit tool_calls?) --"
  probe_tools "$S" >> "$OUT" 2>&1 || w "  (tools probe failed)"

  # 6) recovery_time (kill pod, time to serving again)
  log "[$S] recovery-after-kill"
  w "-- recovery-after-kill --"
  ( "$SCRIPT_DIR/recovery.sh" "$S" 64 2>&1 | grep -E '\{' ) >> "$OUT" 2>&1 || w "  (recovery failed)"

  # 7) SIE-specific: new_conversation_cold (per-conversation relaunch latency)
  if [ "$S" = "sie" ]; then
    log "[sie] new_conversation_cold probe"
    w "-- new_conversation_cold (SIE per-conversation relaunch) --"
    probe_new_conversation "$S" >> "$OUT" 2>&1 || w "  (new-conversation probe failed)"
  fi

  w '```'
  w ""
}

# --- probes (hit the server via a short port-forward) ---
_url_for(){ case "$1" in sie) echo sie-gateway.sie:8080;; *) echo "$1.inference:8000";; esac; }
_pf(){ # $1=server -> exports PF_URL localhost, sets PF_PID
  local hp; hp="$(_url_for "$1")"; local ns="${hp%%.*}"; :
}

probe_context(){
  local S="$1" svc port ns
  case "$S" in sie) svc=sie-gateway; ns=sie; port=8080;; *) svc="$S"; ns=inference; port=8000;; esac
  kubectl -n "$ns" port-forward "svc/$svc" 18030:$port >/dev/null 2>&1 & local pf=$!
  sleep 4
  python3 - "$MODEL" <<'PY'
import json,urllib.request,sys
model=sys.argv[1]
# ~32K tokens of filler (~4 chars/token)
filler=("The analytics workspace holds sales, customers, products, orders, returns "
        "and inventory across regions and time. ")*1400
body=json.dumps({"model":model,"messages":[{"role":"user","content":filler+"\n\nIn one word, what domain is this?"}],
                 "max_tokens":16,"temperature":0,"chat_template_kwargs":{"enable_thinking":False}}).encode()
req=urllib.request.Request("http://localhost:18030/v1/chat/completions",data=body,headers={"Content-Type":"application/json","Authorization":"Bearer local"})
try:
    import time;t=time.time()
    r=json.loads(urllib.request.urlopen(req,timeout=120).read())
    print(json.dumps({"probe":"context32k","ok":True,"approx_input_tokens":len(filler)//4,
                      "finish":r["choices"][0].get("finish_reason"),"latency_s":round(time.time()-t,1)}))
except Exception as e:
    print(json.dumps({"probe":"context32k","ok":False,"error":str(e)[:160]}))
PY
  kill $pf 2>/dev/null || true
}

probe_tools(){
  local S="$1" svc port ns
  case "$S" in sie) svc=sie-gateway; ns=sie; port=8080;; *) svc="$S"; ns=inference; port=8000;; esac
  kubectl -n "$ns" port-forward "svc/$svc" 18031:$port >/dev/null 2>&1 & local pf=$!
  sleep 4
  python3 - "$MODEL" <<'PY'
import json,urllib.request,sys
model=sys.argv[1]
body=json.dumps({"model":model,"messages":[{"role":"user","content":"What's the weather in Prague? Use the tool."}],
  "tools":[{"type":"function","function":{"name":"get_weather","description":"Get weather",
    "parameters":{"type":"object","properties":{"city":{"type":"string"}},"required":["city"]}}}],
  "tool_choice":"auto","max_tokens":256,"temperature":0}).encode()
req=urllib.request.Request("http://localhost:18031/v1/chat/completions",data=body,headers={"Content-Type":"application/json","Authorization":"Bearer local"})
try:
    r=json.loads(urllib.request.urlopen(req,timeout=120).read())
    tc=r["choices"][0]["message"].get("tool_calls")
    print(json.dumps({"probe":"function_calling","emits_tool_calls":bool(tc),
                      "call":[(t["function"]["name"],t["function"]["arguments"]) for t in (tc or [])],
                      "finish":r["choices"][0].get("finish_reason")}))
except Exception as e:
    print(json.dumps({"probe":"function_calling","ok":False,"error":str(e)[:160]}))
PY
  kill $pf 2>/dev/null || true
}

probe_new_conversation(){
  # SIE may spin per-conversation state; measure first-token of a fresh conversation
  # after a short idle gap vs steady-state. Interpret on the day (SIE-specific).
  local S="$1" svc port ns; svc=sie-gateway; ns=sie; port=8080
  kubectl -n "$ns" port-forward "svc/$svc" 18032:$port >/dev/null 2>&1 & local pf=$!
  sleep 4
  python3 "$SCRIPT_DIR/loadtest.py" --base-url http://localhost:18032/v1 --model "$MODEL" \
    --concurrency 1 --requests 1 --max-tokens 32 --disable-thinking --json 2>/dev/null \
    | python3 -c "import json,sys; d=json.load(sys.stdin); print(json.dumps({'probe':'new_conversation_cold','first_token_s':d.get('ttft_p50_s'),'e2e_s':d.get('e2e_p50_s')}))" 2>/dev/null \
    || echo '{"probe":"new_conversation_cold","error":"failed"}'
  kill $pf 2>/dev/null || true
}

# ---------- run ----------
for S in $SERVERS; do run_server "$S"; done

# ---------- scaling: scale_to_zero_time (measured once at the end) ----------
log "measuring scale_to_zero_time"
w "## scaling — scale_to_zero_time"
w '```'
T0=$(python3 -c 'import time;print(f"{time.time():.0f}")')
teardown
until [ "$(kubectl get nodes -l workload=inference --no-headers 2>/dev/null | grep -c .)" = "0" ]; do
  sleep 15
  [ $(( $(python3 -c 'import time;print(int(time.time()))') - T0 )) -gt 1200 ] && { w "  scale_to_zero_time_s: >1200 (timeout)"; break; }
done
T1=$(python3 -c 'import time;print(f"{time.time():.0f}")')
w "  scale_to_zero_time_s: $(( T1 - T0 ))"
w '```'

log "DONE — results in $OUT   (GPU workloads torn down)"
echo "===== $OUT ====="
cat "$OUT"
