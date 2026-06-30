# Serving benchmark — Qwen3-4B-Instruct-2507 on 1× L40S 48GB

First credible serving-layer comparison of the three providers (Track B).
Apples-to-apples: same model, same GPU, same load generator. Run 2026-06-30.

**Method (why credible):** load generator runs *inside* the cluster hitting the
Service directly (no `kubectl port-forward`, which inflated TTFT ~6×: 0.42s→0.06s);
5 warmup requests discarded; n = 25/100/200/400 at concurrency 1/4/8/16; streaming,
max_tokens=128, temp=0. Scripts: `incluster-bench.sh`, `loadtest.py`, `coldstart.sh`.

---

## 1. Warm latency & throughput (model resident)
*TTFT = time to first token. TPOT = time per output token (decode speed). e2e = full request.*

| metric | **SIE 0.6.14** | **SGLang** | **vLLM** |
|---|---|---|---|
| TTFT p50 @ c=1 | 0.063 s | **0.028 s** | 0.048 s |
| TTFT p50 @ c=16 | 0.090 s | 0.047 s | 0.069 s |
| TPOT (decode) | **~11 ms** | ~12 ms | ~20 ms |
| e2e p95 @ c=16 | 0.84 s | 0.81 s | 1.39 s |
| throughput @ c=1 | 83 tok/s | 83 tok/s | 49 tok/s |
| throughput @ c=8 | 608 tok/s | (366*) | 360 tok/s |
| throughput @ c=16 | **1156 tok/s** | (1207*) | 706 tok/s |

\* SGLang throughput under concurrency is unreliable — see errors below.

## 2. Stability (error rate under load)
*Share of failed/timed-out requests. The single most decision-relevant column.*

| concurrency | SIE | SGLang | vLLM |
|---|---|---|---|
| 1 | 0 % | 0 % | 0 % |
| 4 | 0 % | **32 %** | 0 % |
| 8 | 0 % | **79 %** | 0 % |
| 16 | 0 % | **30 %** | 0 % |

SGLang standalone melts under concurrency (no admission control → KV-cache
exhaustion). SIE = same SGLang engine **+ gateway admission control** → 0 %.
vLLM → 0 %. **Provider ≠ just its engine.**

## 3. Cold start & scaling
*How long from nothing to serving. Matters for scale-to-zero / on-demand.*

| phase | value | note |
|---|---|---|
| model load (4B, node up) | **~130 s** (vLLM, measured) | weights load + warmup; SIE/SGLang 4B similar order |
| GPU node provision (EKS scale 0→1) | ~3–5 min (observed) | on top of model load when starting from parked |
| scale-to-zero (node removed) | ~10 min (observed) | autoscaler reclaims the GPU node |
| 27B cold load | vLLM only | SIE/SGLang OOM before serving (see §5) |

Full per-server cold sweep is a follow-up (each needs a scale-to-zero cycle = node
re-provision). `coldstart.sh` automates the phases.

## 4. Resource utilisation
*GPU compute % and VRAM at idle (4B resident).*

| | vLLM 4B |
|---|---|
| GPU util (idle) | 0 % |
| VRAM "used" | 41.9 / 46 GB |

⚠️ The 41.9 GB is **not** the 4B's footprint (~8 GB) — vLLM pre-reserves the KV
pool at `--gpu-memory-utilization=0.90`. So "VRAM used" reflects the configured
pool, not model size. (Relevant when judging headroom / co-location.)

## 5. Fit matrix — which server runs which model on the L40S 48GB

| model | vLLM | SGLang | SIE |
|---|---|---|---|
| **Qwen3.6-27B FP8** | ✅ fits | ❌ OOM | ❌ OOM |
| gemma-4-26B-A4B (MoE) | — | ❌ OOM | ❌ OOM |
| Qwen3-4B | ✅ | ✅ (unstable@load) | ✅ |

**27B on the L40S = vLLM only.** SIE/SGLang FP8 for these MoE/hybrid models exceed
48 GB; they need ≥80 GB or a smaller model. (Superlinked: no L40S/48GB FP8 27B profile.)

---

## Bottom line
- **SIE** — best 4B balance: stable (0 % errors) + fastest decode (11 ms TPOT, 1156 tok/s). The gateway/admission layer is what keeps it stable.
- **SGLang standalone** — fastest single-shot (28 ms TTFT) but unstable under load; needs `--max-running-requests` tuning. Tunable, not fundamental.
- **vLLM** — rock-solid (0 % errors) but ~2× slower decode (`--enforce-eager`, no CUDA graphs — carried from the 27B config) **and the only server that fits 27B**.

## Caveats / next
- SGLang errors are with default admission — re-run with `--max-running-requests` + lower mem-fraction for a fair stable number.
- vLLM 4B is `--enforce-eager` (config-consistent with 27B); CUDA graphs would raise its throughput.
- Cold-start §3 is partly measured / partly observed — full sweep via `coldstart.sh` pending. Recovery-after-kill not yet tested.
