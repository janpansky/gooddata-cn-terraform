# Serving benchmark — Qwen3.6-27B FP8 on 1× L40S 48GB (Track B)

Stress test of the **production model** on a single mid-tier GPU. Companion to
`results-4b-l40s.md` (which compared all three servers on a small model). Here we
push the real 27B on the only server that fits it on 48 GB — **vLLM**. Run 2026-07-01.

**Method (why credible):** load generator runs *inside* the cluster hitting the
Service directly (no `kubectl port-forward`, which inflates TTFT ~6×); 5 warmup
requests discarded per level; concurrency sweep 1/4/8/16/32; streaming, temp=0,
max_tokens=128, **input padded to 2048 tokens** (realistic agentic prefill = system
prompt + tools + context, not a one-liner). Scripts: `incluster-bench.sh`, `loadtest.py`.

Two passes: **thinking-OFF** (matches production gen-ai, which sends
`enable_thinking=false`) is the primary read; **thinking-ON** is a heavier-load
cross-check on stability.

---

## What each metric means

- **TTFT** (Time To First Token) — from request sent to first token back. = prompt
  *prefill* (processing the 2048 input tokens) + queue wait. This is perceived
  *responsiveness*.
- **TPOT** (Time Per Output Token) — mean gap between subsequent tokens while
  generating. `1/TPOT` = tokens/s per stream. This is *how fast text flows*.
- **e2e** (end-to-end) — full request time = `TTFT + output_tokens × TPOT`.
- **throughput tok/s** — aggregate tokens/s across all concurrent streams = server
  *capacity*.
- **error rate** — share of failed/timed-out requests = *stability* (the single most
  decision-relevant column for an infra track).
- **p50 / p95 / p99** — median / 95th / 99th percentile. p50 = typical user, p95/p99 =
  the tail (worst 1-in-20 / 1-in-100).
- **concurrency** — simultaneous in-flight requests = N users hitting at once.

---

## 1. Production config — thinking-OFF (Qwen3.6-27B, 2048-token prefill)

| concurrency | errors | TTFT p50 | TTFT p95 | TPOT | e2e p50 | e2e p99 | throughput |
|---|---|---|---|---|---|---|---|
| 1  | **0 %** | 0.39 s | 0.40 s | 81 ms  | 5.7 s  | 5.8 s  | 12 tok/s |
| 4  | **0 %** | 0.78 s | 3.41 s | 112 ms | 6.8 s  | 15.7 s | 32 tok/s |
| 8  | **0 %** | 0.84 s | 4.77 s | 185 ms | 13.6 s | 18.5 s | 40 tok/s |
| 16 | **0 %** | 1.26 s | 8.72 s | 220 ms | 16.8 s | 24.5 s | 62 tok/s |
| 32 | **0 %** | 2.03 s | 9.01 s | 292 ms | 22.1 s | 33.0 s | 94 tok/s |

## 2. Heavy-load cross-check — thinking-ON

*Qwen3 emits a long `<think>` block first; caps at max_tokens=128. TTFT/TPOT read
null because this vLLM image buffers reasoning text (returns token count via `usage`,
not incremental deltas) — so read this table for **stability + e2e** only.*

| concurrency | errors | e2e p50 | e2e p99 | throughput |
|---|---|---|---|---|
| 1  | **0 %** | 10.6 s | 10.7 s | 12 tok/s  |
| 4  | **0 %** | 11.9 s | 12.4 s | 43 tok/s  |
| 8  | **0 %** | 13.0 s | 14.6 s | 78 tok/s  |
| 16 | **0 %** | 15.1 s | 19.3 s | 134 tok/s |
| 32 | **0 %** | 20.5 s | 29.5 s | 199 tok/s |

---

## 3. Are these numbers good?

**✅ Excellent — stability.** 0 % errors at *every* level up to 32 concurrent, both
passes. No OOM, no drops, no timeouts. This is the headline: the serving layer is
production-grade stable on a single 48 GB card. Exactly what Track B set out to prove.

**✅ Good — responsiveness (TTFT).** 0.39 s to first token for one user (with a
realistic 2048-token prompt), ≤1.3 s up to 16 concurrent. Snappy for an agentic
assistant.

**⚠️ Weak spot — decode speed (TPOT 81–292 ms/token).** A tuned vLLM does 20–40 ms.
We're ~2–4× slower because we run `--enforce-eager` (CUDA graphs disabled) — required
because 27B FP8 + 32K context + graphs overflow 48 GB. **Known lever:** bigger GPU or
lower context → re-enable CUDA graphs → ~2–3× faster decode.

**⚠️ Tail under load (TTFT p95 8.7–9.0 s @ c≥16).** Prefilling 2048 tokens × 16–32
concurrent contends on one card. Median stays fine; the tail grows.

**Context that makes it viable.** This is *one* mid-tier GPU (L40S 48 GB, ~$1.8/hr
g6e.xlarge) running a 27B model of ~GPT-5.2 quality. At 12 tok/s output the text
streams ~2.5× faster than a human reads → *feels* responsive. For an internal / pilot
assistant with a handful of simultaneous users: **fully usable today.** For DATEV-scale
production: (a) re-enable CUDA graphs on a larger card for ~2–3× decode, and/or
(b) scale horizontally — throughput scales with replicas because stability holds.

---

## 4. Fit reminder (from `results-4b-l40s.md`)

**27B on the L40S 48 GB = vLLM only.** SIE/SGLang OOM on 27B (their FP8 profiles target
80–96 GB). On this GPU, SIE/SGLang are viable only for a smaller model (Qwen3-4B).
→ Feedback to Superlinked: no FP8 profile sized for L40S/48 GB.

## Caveats / next
- Decode is `--enforce-eager`-bound; a CUDA-graph run on a ≥80 GB card is the obvious
  follow-up to quantify the 2–3× decode gain.
- Cold start (scale-from-zero → serving) not re-measured here; see `coldstart.sh` /
  `results-4b-l40s.md` §3. Recovery-after-kill still pending.
- thinking-ON TTFT/TPOT are null (image buffers reasoning) — not a server defect, a
  measurement artifact; use thinking-OFF for latency.
