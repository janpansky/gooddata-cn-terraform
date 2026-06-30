# Serving benchmark — Qwen3-4B-Instruct-2507 on 1× L40S 48GB

First credible serving-layer comparison (Track B). Apples-to-apples: same model
(`Qwen/Qwen3-4B-Instruct-2507`), same GPU (1× L40S 48GB), same load generator.

**Methodology** (why these are credible, vs the earlier port-forward smoke test):
- **in-cluster runner** — `loadtest.py` runs as a Job inside the cluster hitting
  the Service directly (`incluster-bench.sh`). No `kubectl port-forward` → no
  laptop↔cluster RTT (that inflated TTFT ~6×: 0.42s port-forward vs 0.06s in-cluster).
- **warmup discard** — first 5 requests discarded (first-request compile / CUDA-graph capture).
- **sample** — n = 25 / 100 / 200 / 400 requests at concurrency 1 / 4 / 8 / 16.
- streaming Chat Completions, max_tokens=128, temperature=0. Run 2026-06-30.

## Warm scoreboard

| metric | **SIE 0.6.14** | **SGLang (standalone)** | **vLLM** |
|---|---|---|---|
| TTFT p50 (c=1) | 0.063 s | **0.028 s** | 0.048 s |
| TTFT p50 (c=16) | 0.090 s | 0.047 s | 0.069 s |
| TPOT (per-token) | **~11 ms** | ~12 ms | ~20 ms |
| throughput (c=1) | 83 tok/s | 83 tok/s | 49 tok/s |
| throughput (c=8) | 608 tok/s | (366, errors) | 360 tok/s |
| throughput (c=16) | **1156 tok/s** | (1207, errors) | 706 tok/s |
| **error rate** | **0 % (all levels)** | **30–79 % (c ≥ 4)** | **0 % (all levels)** |

## Findings

1. **SIE is the best balance on 4B** — stable (0 % errors at every concurrency)
   AND fast (lowest TPOT ~11 ms, highest stable throughput 1156 tok/s).
2. **SGLang standalone is fastest single-shot** (TTFT 28 ms at c=1) but
   **unstable under concurrency** (30–79 % errors at c≥4, one level hit 37 s p95).
   Likely cause: no admission control (`--max-running-requests` unset) + mem-fraction
   0.85 → KV-cache exhaustion under concurrent load. **Tunable, not fundamental.**
3. **The orchestration layer matters:** SIE *is* SGLang underneath + a gateway with
   admission control → it stays at 0 % errors where bare SGLang melts. So a provider
   ≠ just its engine.
4. **vLLM is rock-solid** (0 % errors) but **~2× slower per token** (TPOT 20 ms,
   throughput caps at 706 tok/s). Reason: we run it `--enforce-eager` (no CUDA
   graphs) — required for 27B on the L40S, carried over to 4B here. With CUDA
   graphs enabled for 4B it would be faster; benchmark kept config-consistent.

## Fit matrix (which server runs which model on the L40S)

| model | vLLM | SGLang | SIE |
|---|---|---|---|
| **Qwen3.6-27B FP8** | ✅ fits | ❌ OOM | ❌ OOM |
| gemma-4-26B-A4B (MoE) | — | ❌ OOM | ❌ OOM |
| Qwen3-4B | ✅ | ✅ (unstable@load) | ✅ |

→ **27B on the L40S = vLLM only.** SIE/SGLang FP8 for these MoE/hybrid models
exceeds 48 GB; they need a ≥80 GB GPU or a smaller model. (Finding for Superlinked:
no L40S/48 GB FP8 profile for 27B.)

## Caveats / next
- SGLang errors are with default admission — re-run with `--max-running-requests`
  + lower mem-fraction for a fair stable number.
- vLLM 4B run is `--enforce-eager` (config-consistent with 27B); a CUDA-graph run
  would raise its throughput.
- Cold-start (`coldstart.sh`) not yet folded into this scoreboard — warm only.
