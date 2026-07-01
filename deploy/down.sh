#!/usr/bin/env bash
set -euo pipefail

###
# Scale all GPU workloads to zero replicas.
#
# After scaling down, the EKS cluster autoscaler removes the g6e.12xlarge GPU
# node (~10 min). No GPU cost is incurred while all workloads are at zero.
#
# To bring everything back: ./up.sh
###

echo ">> Scaling vLLM to 0..."
kubectl -n inference scale deploy/vllm --replicas=0 2>/dev/null \
    && echo "   done" \
    || echo "   (vllm not found — already down or namespace missing)"

echo ""
echo ">> Scaling SIE sglang workers to 0..."
# SIE workers are StatefulSets named sie-<pool>-<bundle>-<index>.
# Scaling the StatefulSets directly is more reliable than via labels.
for sts in $(kubectl -n sie get statefulset -o name 2>/dev/null | grep -i worker || true); do
    kubectl -n sie scale "$sts" --replicas=0 && echo "   $sts → 0"
done
# Fallback: scale by label selector (catches any naming variants)
kubectl -n sie scale statefulset \
    -l app.kubernetes.io/component=worker \
    --replicas=0 2>/dev/null || true

echo ""
echo "Done. GPU node will drain and terminate in ~10 min (EKS autoscaler)."
echo "Cost: \$0 GPU charges while nodes are absent."
echo ""
echo "To restart:  ./up.sh"
echo "To verify:   ./status.sh"
