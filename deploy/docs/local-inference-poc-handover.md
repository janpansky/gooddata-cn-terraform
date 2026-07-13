# Local Inference PoC — Engineering Handover

**Status:** PoC closed. **Decision: SIE (Superlinked) as the serving layer**, vLLM as validated fallback.
**Audience:** engineering review / handover. Business/customer framing lives separately.

---

## 1. Decision & rationale
- **SIE won the serving-engine head-to-head** (SIE / SGLang / vLLM — same 4B model, same L40S, same load): **0 % errors + fastest decode**, thanks to its gateway/admission control. SGLang without admission control melted (30–79 % errors under load).
- **vLLM = fallback** — the *only* engine that fit Qwen3.6-27B on a 48 GB L40S (FP8 + `--enforce-eager`). SIE/SGLang OOM on 27B at 48 GB (they need ≥80 GB).
- SIE is open source and runs on our own infra.

## 2. How it sits in GoodData CN
The AI assistant is the **`gen-ai`** microservice. It reaches the LLM through a **provider abstraction (BYOLLM)** — `llm_factory.py` routes to adapters: OpenAI / Azure Foundry / AWS Bedrock / Anthropic / **Local**.

- **Our change:** OpenAI-with-baseUrl **and** the new **Local** provider → `ChatCompletionsLlmAdapter` → point gen-ai at an **in-cluster** OpenAI-compatible endpoint: `http://vllm.inference.svc.cluster.local:8000/v1` (vLLM) or the SIE gateway. **LLM traffic never leaves the cluster.**
- **Two models, both local:** the generative LLM (gen-ai) + **embeddings for AI Knowledge / RAG** (TEI today, SIE can also serve) → vectors in Qdrant.
- **Harness hardening** (why an open model completed the full agentic flow set_skills→tool→render):
  - `conversation_service.py` — wrap the final answer so the **visualization renders** on the Local path (Responses adapter did this automatically; Chat Completions didn't).
  - `base_tool.py` — **coerce stringified tool arguments** (qwen3_coder parser serializes nested args as strings → pydantic errors).
  - `tool_registry.py` — **repair hallucinated tool names** (difflib + alias table).
  - `chat_completions_llm.py` + `llm_factory.py` — **disable Qwen "thinking"** via `extra_body.chat_template_kwargs`, gated by env `LOCAL_LLM_DISABLE_THINKING` (default off, model-neutral).
- **Deploy:** terraform stands up EKS + a GPU node pool (Bottlerocket NVIDIA) + CN (helm) + the inference server (vLLM manifest / SIE helm). gen-ai image built from the branch → ECR → referenced in tfvars: `services.genAi.image = …/local-inference/gen-ai:jan-local-inference-14`.

## 3. Where the code lives (git)
| Component | Repo | Branch | Key paths |
|---|---|---|---|
| Gen-ai / CN integration (Local provider + harness fixes) | `github.com/janpansky/gdc-nas` | `jan/local-inference` | `microservices/gen-ai/app/...`: `llm_factory.py`, `conversation_service.py`, `base_tool.py`, `tool_registry.py`, `chat_completions_llm.py` |
| Deploy + infra + benchmarks | `github.com/janpansky/gooddata-cn-terraform` | `jan/jan-inference-env` | `deploy/`: `deploy.sh`, `envs/`, `k8s/vllm-qwen.yaml`, `helm/install-sie.sh` + `sie-values.yaml`, `inference/use-server.sh`, `infra-bench/` |
| Shared deploy branch (with Peter) | same | `jan/independent-deploy` | same; Peter commits here too |

**Results & methodology:** `deploy/infra-bench/` → `results-4b-l40s.md`, `results-27b-l40s.md`, `results-27b-sie-endpoint.md`, `H100-RUN-LOG.md`.
**Reusable harness:** `infra-bench/loadtest.py`, `incluster-bench.sh` (in-cluster load gen — port-forward inflated TTFT ~6×), `coldstart.sh`, `recovery.sh`, `gpu-snapshot.sh`, `h100-day.sh`.

## 4. Key findings
- **27B ≈ GPT-5.2 quality; 14B insufficient.** A non-frontier model runs the full agentic flow **only with the hardened harness** — harness quality matters as much as model size.
- **Fit matrix (48 GB L40S):** 27B = vLLM-only; SIE/SGLang need ≥80 GB. **SIE has no FP8/48 GB profile → open feedback item to Superlinked.**
- **SIE on 27B (their 96 GB cluster):** 0 % errors, ~12 ms/token decode, function-calling works — **but the shared managed pool is not production-grade** (cold-loads stuck 28–60+ min, 503 evictions, `/health`=loaded while serving fails). **→ production must be a pinned single-tenant deployment, never a shared pool.**
- **Decode on L40S is `enforce-eager`-bound** (81–292 ms/tok); CUDA graphs need 80 GB headroom.

## 5. Open items (NOT finished)
- **Same-hardware 3-way on 27B** — needs an 80 GB GPU. Blocked ~2 days by an **AWS GPU capacity crunch** (H100, A100, and even L40S all `InsufficientInstanceCapacity` across regions/AZs). Supply problem, not code.
- **SIE 32K context + c=16 on 27B** — never verified (their cluster outage).
- **CUDA-graph decode speedup** — not quantified.
- Each needs a **reserved** 80 GB GPU (Capacity Block us-west-2 ~$104/day, or a Superlinked-provided node). On-demand is unreliable for these SKUs.

## 6. Next engineering workstreams
- **Pinned single-tenant SIE** deployment pattern (the reliability fix).
- **LoRA pipeline** for domain accuracy: mine the semantic layer → synthetic (query, passage) pairs → tune the **embedder** (retrieval) → serve many adapters on SIE (embedder LoRA first; generative LoRA later for agentic reliability). German-legal embedder LoRA precedent: +18 % retrieval for ~$0.80.
- **Agentic reliability** — harden the harness further and/or a generative LoRA on agentic traces.
- **Reserve GPU** for the finish-line benchmarks.

## 7. Infra state / cost
- Both PoC envs (`jan-inference` us-east-1, `jan-inference-eu` Frankfurt) **destroyed** — no spend.
- Peter's `local-inference` (us-east-1) **parked** (nodegroups desired=0) but its **RDS still runs**.
- No GPU instances running anywhere.

## ⚠ Action items for the meeting
1. **Push both branches** — the latest local commits (esp. `jan-inference-env` wrap-up `bd797f2`) are **not on the remote** (blocked on SSH key `~/.ssh/jp` passphrase). Currently only on the author's machine.
2. **Decide owner** of the benchmark harness (make it a repeatable asset).
3. **Decide:** reserve an 80 GB slot to close the 3-way + 32K, or call the PoC done on current evidence.
