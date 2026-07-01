# H100 day — runbook

Goal: get SIE numbers on Qwen3.6-27B (impossible on our 48GB L40S), vLLM as baseline,
on a single H100 80GB rented for 1 day via an EC2 Capacity Block (~$104). Everything
runs from **one command**; the harness tears the GPU down on exit so no idle H100 burns.

## Budget & isolation (built in)
- `h100-day.sh` refuses to run unless kubectl context is **jan-inference** and the GPU
  node is a **p5\*** (H100). GPU nodegroup max stays **1** → never a 2nd H100.
- On any exit (finish / error / Ctrl-C) it scales vLLM + SGLang + SIE workers to **0**.
- The Capacity Block is prepaid for its 24h window — cost is fixed once booked ($104);
  the whole suite runs in ~2–3h, so there's slack, but don't book two blocks.

## Day-of steps

**1. Book the Capacity Block** (do this ahead — earliest slot was 2026-07-15):
```
aws ec2 describe-capacity-block-offerings --region us-east-1 \
  --instance-type p5.4xlarge --instance-count 1 --capacity-duration-hours 24
aws ec2 purchase-capacity-block --region us-east-1 --capacity-block-offering-id <id> \
  --instance-platform Linux/UNIX
# -> note the CapacityReservationId
```

**2. Point the GPU nodegroup at the H100 for the reserved window** (jan-inference env):
- Set in `deploy/envs/jan-inference/settings.tfvars`:
  `inference_gpu_instance_type = "p5.4xlarge"`
- Target the reservation. Capacity Block instances must launch *into* the reservation —
  the managed nodegroup needs a `capacity_reservation_specification` (capacity-blocks /
  `CapacityReservationId`) on its launch template. **This may need a small addition to
  `aws/eks.tf`** (the current nodegroup has no reservation target). Prepare/verify before
  the day. Then: `AWS_PROFILE=aws-panther-dev GDCN_LICENSE_KEY=... ./deploy/deploy.sh jan-inference apply`

**3. Bring up the servers on the H100:**
- vLLM: on 80GB, **drop `--enforce-eager`** in `deploy/k8s/vllm-qwen.yaml` to enable CUDA
  graphs (the ~2–3× decode gain we want to quantify), then `kubectl apply -f`.
- SIE: `./deploy/helm/install-sie.sh` with the **h100 profile** (verify the worker
  StatefulSet name + the model profile suffix — see "tweak on the day" below).

**4. Run everything:**
```
cd deploy/infra-bench
AWS_PROFILE=aws-panther-dev ./h100-day.sh
```
Writes `results-27b-h100.md`; prints it at the end; tears the GPU down.

**5. Confirm teardown** (belt & braces): `kubectl get nodes -l workload=inference` → empty.

## What it measures (per server: vLLM, SIE)
- **Cold start**: provision_ready (=scale_up_time), first_request_warmup, cold_full; SIE also new_conversation_cold.
- **Warm latency**: TTFT, TPOT, e2e p50/p95/p99.
- **Throughput**: tokens/s, req/s across the sweep → saturation_concurrency.
- **Scaling**: scale_up_time (cold start), scale_to_zero_time (once, at end).
- **Stability**: error_rate (sweep), recovery_time (recovery.sh), GPU util / VRAM (gpu-snapshot.sh).
- **Hard requirements**: 32K context probe, function-calling probe (agentic prerequisite).

## Tweak on the day (can't be verified without the H100 — flagged honestly)
- **SIE worker StatefulSet name** and **model profile suffix** depend on what
  `install-sie.sh` deploys with the h100 profile. `recovery.sh sie` defaults to
  `sie-worker-h100-sglang` / `Qwen/Qwen3.6-27B:h100`; override with
  `SIE_WORKLOAD=... SIE_MODEL=...` if the installed names differ. Check `use-server.sh`
  registry (it currently lists the L4 worker + `:no-spec`) and update the `sie` row.
- **SIE S3 cache bucket**: `deploy/helm/sie-values.yaml` must point at this env's bucket
  (`s3://jan-inference-model-cache-972873489489/models`).
- **SIE profile that fits 80GB**: `:h100` (FP8, 80GB-sized) or `:no-spec` (BF16 ~54GB,
  also fits H100). Try `:h100` first.
- `new_conversation_cold` is a best-effort probe of SIE's per-conversation relaunch —
  interpret the number against steady-state TTFT on the day.
