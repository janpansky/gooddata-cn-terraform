#!/usr/bin/env bash
set -euo pipefail
###
# GPU utilisation + VRAM snapshot on the inference GPU node. Runs `nvidia-smi` in
# a short-lived pod pinned to the GPU node pool, so we capture real device numbers
# (not the pod's cgroup view). Emits JSON: gpu_util_pct, vram_used_mib, vram_total_mib.
#
# Usage: ./gpu-snapshot.sh   (label it via LABEL=... for context in output)
###
LABEL="${LABEL:-snapshot}"
NS="${NS:-default}"
POD="gpu-snap-$RANDOM"

# nvidia-smi is present in the CUDA runtime image; toleration+selector land it on
# the GPU node. Requesting a GPU guarantees co-location with the model's device.
cat <<YAML | kubectl -n "$NS" apply -f - >/dev/null
apiVersion: v1
kind: Pod
metadata:
  name: $POD
  labels: { app: gpu-snap }
spec:
  restartPolicy: Never
  nodeSelector: { workload: inference }
  tolerations:
    - { key: workload, value: inference, effect: NoSchedule }
  containers:
    - name: smi
      image: nvidia/cuda:12.4.1-base-ubuntu22.04
      command: ["bash","-c","nvidia-smi --query-gpu=utilization.gpu,memory.used,memory.total --format=csv,noheader,nounits"]
      resources: { limits: { nvidia.com/gpu: 1 } }
YAML

kubectl -n "$NS" wait --for=condition=Ready "pod/$POD" --timeout=120s >/dev/null 2>&1 || true
# pod is short-lived; wait for it to finish then read logs
for _ in $(seq 1 30); do
  ph=$(kubectl -n "$NS" get pod "$POD" -o jsonpath='{.status.phase}' 2>/dev/null)
  [ "$ph" = "Succeeded" -o "$ph" = "Failed" ] && break; sleep 2
done
OUT=$(kubectl -n "$NS" logs "$POD" 2>/dev/null | tail -1)
kubectl -n "$NS" delete pod "$POD" --wait=false >/dev/null 2>&1 || true

python3 - "$LABEL" "$OUT" <<'PY'
import sys
label, out = sys.argv[1], sys.argv[2].strip()
try:
    util, used, total = [x.strip() for x in out.split(",")]
    print(f'{{"snapshot":"{label}","gpu_util_pct":{int(util)},"vram_used_mib":{int(used)},"vram_total_mib":{int(total)}}}')
except Exception:
    print(f'{{"snapshot":"{label}","raw":"{out}","error":"could not parse nvidia-smi"}}')
PY
