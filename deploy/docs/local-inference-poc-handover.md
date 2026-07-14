# Local Inference PoC — Handover (Product + Engineering)

**What:** run GoodData's AI-assistant models (generative + embeddings) **fully self-hosted**, inside the customer's environment — nothing leaves.
**Outcome:** PoC closed. **Decision: SIE (Superlinked) is the serving layer.** vLLM is the validated fallback.
**Owner going forward:** PS hands the serving layer to **Product**; PS continues on customer use cases + model fine-tuning.

---

## Why it matters (the capability)
Today the AI assistant sends aggregated data to an external LLM (OpenAI/Azure). Sovereignty customers (DATEV) can't allow that in production. **This PoC proves we can run the whole thing locally at frontier-level quality** — which unblocks AI in those environments, not just demos.

## Results (headline)
- **Serving-engine head-to-head** (SIE / SGLang / vLLM — same model, same GPU, same load): **SIE won** — fastest decode + **0 % errors under load** (its admission control; SGLang without it hit 30–80 % errors).
- **Quality:** the open 27B model ≈ frontier quality; the **full agentic flow** (search → analysis → chart in the UI) ran entirely local.
- **Caveat:** SIE's engine is great, but a **shared multi-tenant cluster is not production-grade** (model cold-loads/evictions). **Production = pinned single-tenant deployment.**

Full numbers & methodology: `deploy/infra-bench/results-*.md` + `H100-RUN-LOG.md`.

---

## For Product
- **You now own the serving layer.** It's decided (SIE) and validated; vLLM is the fallback that also fits a smaller GPU.
- **Capability to productize:** self-hosted, sovereign, frontier-quality AI — a clear differentiator for regulated/sovereignty customers.
- **Roadmap items surfaced by the PoC:**
  - **Pinned single-tenant SIE** deployment (the reliability requirement — don't ship on a shared pool).
  - **SIE FP8/48 GB profile** — open ask to Superlinked (today 27B needs ≥80 GB via SIE; vLLM fits 48 GB).
  - **Usage observability** — DATEV explicitly asked to track assistant usage/cost/tokens. Feature gap worth owning.
  - **Fine-tuning per use case** (LoRA) as a customer-facing capability — cheap domain adaptation (German legal embedder: +18 % retrieval for ~$0.80).
- **Customer pull:** DATEV is the target design partner; PS is driving the first use case.

## For Engineering
- **How it's wired in GoodData CN:** the `gen-ai` microservice reaches the LLM via a provider abstraction (BYOLLM). We added a **Local provider** → OpenAI-compatible in-cluster endpoint (`http://vllm.inference.svc.cluster.local:8000/v1` or SIE gateway). Embeddings for AI Knowledge/RAG also served locally (TEI/SIE) → Qdrant.
- **Harness hardening** (why a non-frontier model completes the agentic flow — reusable, model-neutral):
  - render the visualization on the Local path (`conversation_service.py`)
  - coerce stringified tool args (`base_tool.py`)
  - repair hallucinated tool names (`tool_registry.py`)
  - disable model "thinking" via env `LOCAL_LLM_DISABLE_THINKING` (`chat_completions_llm.py`, `llm_factory.py`)
  - **Insight:** harness quality matters as much as model size.
- **Reusable assets:** deploy wrapper (`deploy.sh`, per-env tfvars, GPU node pool terraform, `install-sie.sh`, `use-server.sh`) + a reproducible benchmark suite (`infra-bench/`: `loadtest.py`, `incluster-bench.sh`, `coldstart.sh`, `recovery.sh`, `h100-day.sh`).
- **Open technical items (not finished):** same-hardware 3-way on 27B, SIE 32K-context + c=16, and CUDA-graph decode speedup — all need a **reserved 80 GB GPU** (blocked this week by an AWS GPU-capacity crunch across regions; on-demand H100/A100/L40S all unavailable — reserve, don't rely on on-demand).

---

## Where the code lives
| Part | Repo | Branch |
|---|---|---|
| Gen-ai / CN integration (Local provider + harness) | `github.com/janpansky/gdc-nas` | `jan/local-inference` |
| Deploy + infra + benchmarks + results | `github.com/janpansky/gooddata-cn-terraform` | `jan/jan-inference-env` |

Gen-ai image: `…/local-inference/gen-ai:jan-local-inference-14` (referenced in the env's tfvars).

## Infra state
Both PoC environments **destroyed** — no ongoing cost. No GPU instances running.
