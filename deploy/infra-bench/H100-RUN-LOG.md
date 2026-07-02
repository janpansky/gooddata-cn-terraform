# H100 test run — live log (for Zdenek)

Goal: benchmark **SIE + vLLM on Qwen3.6-27B** on a rented **H100 80GB**, today.
Env: jan-inference (isolated, own state). Suite: h100-day.sh (one command, auto-teardown).

Why H100: SIE (preferred engine) + the 27B model don't fit our 48GB L40S (OOM). H100 80GB
lets us finally benchmark SIE on the real model, and gives headroom for CUDA graphs (faster
decode) + higher capacity.

Approach: on-demand p5.4xlarge (1× H100) NOW — Capacity Block earliest was Jul 15, we need it today.

---
## Timeline
- 2026-07-01 15:44 CEST — Switched jan-inference GPU nodegroup g6e.xlarge (L40S) → p5.4xlarge (H100), terraform apply running. Watching for on-demand capacity.
- 15:53 CEST — Apply done, nodegroup now p5.4xlarge. **InsufficientInstanceCapacity for p5.4xlarge on-demand in us-east-1b** (2 failed launch attempts). Node pinned to 1b (single-AZ). → Widening nodegroup to ALL AZs to improve H100 capacity odds (cache is fresh/S3 in this env, so multi-AZ is safe here).
- 15:55 CEST — Decisions from Jan: if H100 has no capacity anywhere → fall back to A100 80GB (p4de.24xlarge, 8×A100, ~$40/hr). Cost cap $200. Priority = SIE on 27B; if SIE fails, write up findings for the team. SGLang OOM = don't sweat it.
- 15:57 CEST — H100 (p5.4xlarge) InsufficientInstanceCapacity across ALL AZs (multi-AZ retry also failed). Falling back to **A100 80GB (p4de.24xlarge)** per Jan's steer. Note: A100 (Ampere) has no native FP8 → switching model to **BF16** (27B ~54GB fits 80GB). Within-A100 SIE-vs-vLLM on BF16 is still a valid head-to-head. FP8 numbers would need real H100 (Capacity Block Jul 15).
- 16:02 CEST — A100 (p4de.24xlarge) is **Unsupported in our AZs**: our VPC has subnets only in us-east-1a/1b, but p4de is offered only in 1c/1d. H100 (p5.4xlarge) IS AZ-supported here but has no on-demand capacity right now. Decision: go back to **H100 p5.4xlarge + FP8** and run a **retry loop** (failed launches cost $0; H100 capacity fluctuates minute-to-minute). If no capacity within ~90 min → surface as blocker (options: add a 1c/1d subnet for A100 = VPC change, or p5.48xlarge 8×H100 ~$98/hr, or Jul 15 Capacity Block).
- 16:09 CEST — "Make sure you succeed" — escalation ladder to guarantee an 80GB GPU:
  1. H100 p5.4xlarge retry loop (running; $0 on failed launch; capacity fluctuates, good odds overnight).
  2. On timeout → p5.48xlarge (8×H100, different capacity pool, no VPC change; ~$98/hr, run fast <2h to stay <$200).
  3. Then → standalone subnet in us-east-1c + A100 p4de.24xlarge (A100 more available than H100, $40/hr = more runway). Needs a custom aws_subnet (VPC module can't add an AZ without reshuffling CIDRs = env teardown, so a standalone subnet + NAT route + EKS tags instead).
  4. Overnight: keep cheapest H100 1× loop as passive catch.
- 17:58 CEST — H100 loop timed out (83 min, 5 attempts, all InsufficientInstanceCapacity). Executing step 3: added a standalone us-east-1c subnet (10.0.64.0/20, gpu-extra-subnet.tf, routed via existing NAT, EKS-tagged, gated to jan-inference) so **A100 80GB (p4de.24xlarge)** can launch in 1c (A100 is only offered in 1c/1d). GPU nodegroup repinned to the 1c subnet + BF16. Applying, then retry loop for A100 capacity.
- 18:54 CEST — A100 p4de in 1c also InsufficientInstanceCapacity. Both 80GB GPUs on-demand are capacity-blocked right now. Capacity Blocks: earliest H100 Jul 6 ($104), A100 Jul 11 ($354) — neither is "tomorrow". Widening A100 pool to 1c+1d (two capacity pools) + launching a long overnight retry loop. Guaranteed-capacity path (block) is 5+ days out; near-term success depends on on-demand freeing up overnight (out of our control).
- 18:56 CEST — Overnight A100 retry loop running (p4de across 1c+1d, poll 4 min, $0 on failed launch). Blocked purely on AWS on-demand 80GB capacity now — everything else is ready: vLLM manifest (BF16 for A100), benchmark suite (h100-day.sh, one command, auto-teardown). SIE A100 pool profile (machineProfile a100-80gb) to be finalized on the live node. Loop exits 0 the moment a node is up → benchmark runs automatically; 3h timeout → re-arm.
- 19:07 CEST — Pivot to EU: us-east-1 80GB on-demand is dry. eu-central-1 (Frankfurt) offers A100 80GB (p4de) on-demand in eu-central-1a (in the VPC's AZ slice) + we have quota + it's the DATEV/sovereignty region. Standing up new env jan-inference-eu (own state) in eu-central-1, GPU=p4de.24xlarge BF16. init+apply ~35min, then try A100 capacity.
- 19:10 CEST — Paused us-east-1 jan-inference (moved to Frankfurt): all 3 nodegroups scaled to desired=0, RDS stopped. EKS control plane stays (~$0.10/hr, can't pause). Frankfurt env building.
- 19:53 CEST — Frankfurt A100: InsufficientInstanceCapacity too. Retrying.
- 20:00 CEST — Frankfurt A100 (eu-central-1a) also InsufficientInstanceCapacity. 80GB on-demand is dry across all tried regions/AZs (us-east H100+A100, Frankfurt A100). Global GPU crunch. Launching overnight retry loop on Frankfurt 1a ($0 on fail); guaranteed capacity = Capacity Block days out (us-west-2 Jul 4-5).
- 20:12 CEST — Continuous (infinite) retry loop armed on Frankfurt A100 (1a). Polls every 3 min; exits only on node acquired (success) or SSO expiry (re-auth+re-arm).
- 20:42 CEST — still retrying (attempt 11), no A100 capacity yet.
- 20:48 CEST — Loop upgraded: FORCE a fresh launch attempt (toggle desired 0->1) every 5 min — plain set desired=1 was a no-op (ASG backoff), so real attempts were sparse.
- 21:02 CEST — Prepared sie-endpoint-bench.sh: one-command SIE-27B benchmark against the Superlinked managed endpoint (their GPU). Runs the moment we have the SL- token. Endpoint confirmed live (401=up). This unblocks SIE-27B today without our own 80GB GPU. Only blocker: the SL- token from Superlinked.
- 21:20 CEST — still forcing attempts (n=5), InsufficientInstanceCapacity
- 21:21 CEST — SL- token WORKS. SIE managed cluster: 8 GPU, model on rtx6000 (RTX PRO 6000 96GB) pool. Qwen3.6-27B present but cold (MODEL_LOADING). Warming it up, measuring cold-load, then running full SIE-27B benchmark.
- 21:51 CEST — SIE FINDING: managed 27B did NOT warm in 28min via bare 'Qwen/Qwen3.6-27B'. /health lists 'Qwen/Qwen3.6-27B:rtx-pro-6000' as state=loaded, but chat completions to BOTH bare and :rtx-pro-6000 return MODEL_LOADING — health/serving inconsistency (likely eviction/thrash on the shared rtx6000 GPU). Patient warm-loop on :rtx-pro-6000 only (30s poll, 60min), then bench. Feedback for Superlinked either way.
- 21:51 CEST — SIE 27B (:rtx-pro-6000) WARM after 3s. Running benchmark.
- 21:54 CEST — ✅ SIE-27B DATA CAPTURED via Superlinked endpoint. Warm: 0% errors c=1/4/8, TTFT ~0.4s, TPOT 12-26ms (fast — 96GB RTX6000, no enforce-eager), throughput to 115 tok/s. Function-calling WORKS. Reliability finding: flaky cold-load (28min stuck once) + 503 evictions on shared pool (health=loaded but serves MODEL_LOADING/503). 32K context not verified (evicted). Results in results-27b-sie-endpoint.md. AWS A100 loop still running.
- 21:59 CEST — still forcing attempts (n=10), InsufficientInstanceCapacity
- 07:31 CEST — Morning restart: A100 force-loop re-armed (Frankfurt 1a). Overnight: capacity never appeared (ASG retried on its own, last fail 05:25). SIE endpoint model evicted again overnight (MODEL_LOADING) — consistent with the eviction finding.
- 09:09 CEST — SIE 27B failed to load within 60 min this morning — another reliability datapoint.
- 09:09 CEST — A100 loop still trying (n=7), no capacity.
- 09:16 CEST — us-east-1 GPU capacity FULLY dry today: H100, A100, and now L40S g6e.xlarge AND g6e.2xlarge all InsufficientInstanceCapacity across 4 AZs. Region-wide GPU crunch. Armed persistent L40S loop (us-east-1, toggle 5 min) alongside the Frankfurt A100 loop — first catch wins.
- 09:18 CEST — SIE diagnosis: :rtx-pro-6000 now state=loaded but SGLang crashes mid-stream ('stream terminated without terminal event'). Hammering gently until it settles, then running the missing 32K + c=16 tests.
- 09:27 CEST — L40S ACQUIRED us-east-1: ip-10-0-91-255.ec2.internal!
- 09:28 CEST — L40S (g6e.2xlarge) ACQUIRED us-east-1d after 4-AZ widening (attempt 3). Cache PVC was AZ-locked in 1b → deleted+rebound in 1d, model re-downloading. Recovery+coldstart pipeline armed.
- 09:38 CEST — Crash root cause: manifest had lost --quantization=fp8 (A100 edit leftover) → BF16 54GB OOM on 48GB L40S. FP8 restored, pod reloading. Pipeline re-armed.
- 09:40 CEST — SIE managed cluster outage now 3+ hours (MODEL_LOADING/inference_error since ~07:30). Persistent watcher armed (checks every 3 min, runs 32K + c=16 the moment it recovers). Drafting Superlinked support/feedback message.
- 10:10 CEST — A100 loop still trying (n=17), no capacity.
- 11:13 CEST — A100 loop still trying (n=26), no capacity.
- 12:38 CEST — A100 loop still trying (n=36), no capacity.
- 13:06 CEST — WRAP-UP per Jan: all loops stopped, both envs fully parked (nodegroups=0, RDS stopped; only 2× EKS control plane ~$0.20/hr remains). Results delivered: 4B 3-way (L40S), SIE-27B on managed endpoint (perf + reliability findings), vLLM-27B on L40S. Open (documented): SIE 32K + c=16 (their outage), same-hardware 3-way (needs 80GB — Capacity Block option documented: Jul 5 west / Jul 6 east $104).
