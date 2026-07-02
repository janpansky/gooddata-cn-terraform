# SIE on Superlinked managed endpoint — Qwen3.6-27B

SIE serving the **production 27B** on **Superlinked's managed cluster** (their hardware:
8 GPUs, model on the `rtx6000` = RTX PRO 6000 96GB pool, id `Qwen/Qwen3.6-27B:rtx-pro-6000`).
Run 2026-07-01 via their endpoint (external, from laptop). Token from Superlinked (SL-…).

**⚠️ NOT same-hardware vs our vLLM-on-L40S numbers** — different GPU (RTX 6000 96GB vs L40S
48GB). This answers *"does SIE handle 27B well?"* (latency/decode/stability/tools), NOT a
head-to-head serving comparison. For that we still need all servers on one card (our own 80GB).

---

## 1. Warm latency + throughput + stability (thinking-off, input≈2048 tok)
*Captured while the model was resident. 0% errors throughout.*

| concurrency | errors | TTFT p50 | TTFT p95 | TPOT (decode) | e2e p50 | throughput |
|---|---|---|---|---|---|---|
| 1 | **0 %** | 0.41 s | 0.43 s | **12.5 ms** | 0.59 s | 22 tok/s |
| 4 | **0 %** | 0.43 s | 2.96 s | 25.7 ms | 0.57 s | 52 tok/s |
| 8 | **0 %** | 0.47 s | 1.35 s | 24.2 ms | 0.58 s | 115 tok/s |

**Decode is fast** — ~12 ms/token single-stream (≈80 tok/s per stream), vs our vLLM-on-L40S
~80–290 ms (that L40S run was `--enforce-eager`, no CUDA graphs, to fit 48 GB). On the 96 GB
RTX 6000 SIE runs unconstrained → snappy. TTFT ~0.4 s. p95 tail spikes a bit at c=4.

## 2. Function-calling ✅
`get_weather` → `finish_reason: tool_calls`, `{"city":"Prague"}`. **Tool-calling works** on
SIE 27B — the agentic prerequisite is met. (The in-script probe printed "failed" only due to a
transient parse during load; the raw request confirms it works.)

## 3. Reliability — the key finding ⚠️
The managed 27B is **NOT reliably resident** on the shared cluster:
- **Morning after (Jul 2): model failed to load for 60+ min straight** (`MODEL_LOADING` on every
  request from ~07:30, warm-loop gave up at 60 min; still loading after). The 32 K context probe
  could not run at all. Fourth independent observation of the pattern.
- First warm attempt: **MODEL_LOADING for 28 min** (via bare `Qwen/Qwen3.6-27B`), never came up.
- `/health` reported `Qwen/Qwen3.6-27B:rtx-pro-6000` as `state=loaded`, yet completions still
  returned `MODEL_LOADING` — **health/serving inconsistency**.
- Once it settled on `:rtx-pro-6000` it answered in ~3 s and served the whole benchmark at 0 %
  errors — then minutes later returned **HTTP 503** on every request (even 4 K prompts) →
  **evicted again** from the shared GPU.
- **32 K context: not verified** — model was 503/evicted before the context probe.

→ Pattern: **when warm it's fast + stable; but it cold-loads slowly/flakily and gets evicted**
on the shared pool. For production this intermittency matters — needs a pinned/warm
single-tenant deployment, not the shared managed pool. **Feedback for Superlinked** (consistent
with earlier SIE cold-start / eviction findings).

---

## Bottom line
- **SIE handles 27B well when warm**: 0 % errors, 0.4 s TTFT, 12 ms decode, tool-calling works.
- **Availability on the shared managed cluster is flaky**: slow/inconsistent cold-load, 503
  evictions between requests. Not a "just point prod at it" endpoint as-is.
- **Caveat**: their RTX 6000 96 GB, not our card → not comparable to the L40S numbers; use for
  "SIE-on-27B capability", not the same-hardware 3-way.
- **Open**: 32 K context (blocked by eviction), same-hardware SIE-vs-vLLM-vs-SGLang (needs own 80 GB).
