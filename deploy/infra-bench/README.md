# infra-bench — serving-layer / provider benchmark

The **serving-layer** track, separate from `deploy/eval/` (model quality via
`gooddata-eval`). Measures SIE (SGLang) vs vLLM vs others on the **same GPU,
same model, same prompts** — cold start, warm latency/throughput, scaling,
stability. See `metrics.md` for the precise metric definitions and the matrix.

## Why
The pain is serving-layer, not model quality: SIE's readiness timeout, the
per-conversation SGLang relaunch, cold-start cost on an L40S, throughput under
the agentic loop's many sequential calls. `gooddata-eval` measures none of these.

## Files
- `metrics.md` — metric definitions + comparison matrix (agree on this first).
- `coldstart.sh <vllm|sie|sglang>` — cold-start phases (kubectl-orchestrated).
- `loadtest.py` — the load generator (stdlib only): streaming TTFT/TPOT/e2e/throughput, `--warmup` discard.
- `incluster-bench.sh <server> [model]` — **credible** warm benchmark: runs `loadtest.py`
  as a Job INSIDE the cluster (hits the Service directly, no port-forward / laptop-RTT),
  with warmup discard + concurrency sweep + large sample. **Use this, not raw port-forward.**
- `run-matrix.sh` — all servers, cold (`coldstart.sh`) + warm (`incluster-bench.sh`) → scoreboard.

## Credibility (why in-cluster)
Measuring via `kubectl port-forward` from a laptop inflates TTFT/e2e by the tunnel
RTT (observed ~6× on TTFT: 0.42s port-forward vs 0.063s in-cluster for the same
server). `incluster-bench.sh` runs the load generator as a pod in the cluster so
latency is server-side. Warm numbers also use `--warmup` to discard first-request
compile / CUDA-graph capture. Apples-to-apples = same model on every server
(pass a model override; 27B only fits vLLM, so compare on a model that fits all, e.g. Qwen3-4B).

## Run
```bash
# prerequisites: kubectl context on the cluster, python3, GPU available
cd deploy/infra-bench

# single server cold start
./coldstart.sh vllm

# warm sweep against a port-forwarded endpoint
kubectl -n inference port-forward svc/vllm 18000:8000 &
python3 loadtest.py --base-url http://localhost:18000/v1 --model Qwen/Qwen3.6-27B --concurrency 4 --requests 16

# full matrix + scoreboard (sequential — single GPU)
./run-matrix.sh                       # default: vllm sie
CONCURRENCIES="1 4 8 16" ./run-matrix.sh vllm
```

## Notes
- Endpoints are in-cluster; scripts use `kubectl port-forward`.
- **Apples-to-apples:** for a true serving-layer comparison, serve the **same
  model** on both servers (the registry currently has vLLM=27B, SIE=4B — that
  compares each server's own setup, not the bare serving layer). Override the
  model when you want a clean stack comparison.
- `new_conversation_cold` (the SIE per-conversation relaunch) must be measured
  through the **gen-ai chat API**, not the raw `/v1` endpoint — it's a separate
  probe (TODO: `newconv.sh`), since it exercises gen-ai → server, not the server
  directly.
- Cold start scales the GPU node; `provision_ready` includes node provision.
  Pre-warm the node with a placeholder pod to isolate pure model-load time.
