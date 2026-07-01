#!/usr/bin/env bash
set -euo pipefail

###
# Install or upgrade SIE (Superlinked Inference Engine) into the local-inference
# cluster. Handles three things before the helm install:
#
#   1. HuggingFace secret  — sie-hf-token (for gated models; Gemma needs it)
#   2. Custom model configs — ConfigMaps mounted into sie-config for models not
#      in SIE's built-in catalog (Qwen3-14B, Llama-70B AWQ, Gemma-4-26B, 4B variants)
#   3. Helm upgrade        — oci://ghcr.io/superlinked/charts/sie-cluster
#
# After install, wait for the gateway and show how to smoke-test.
#
# Endpoint (in-cluster):
#   http://sie-gateway.sie.svc.cluster.local:8080/v1
###

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEPLOY_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
ENV_FILE="$DEPLOY_DIR/providers/providers.env"

SIE_CHART_VERSION="${SIE_CHART_VERSION:-0.6.14}"
SIE_NAMESPACE="sie"

# ---------------------------------------------------------------------------
# 0. Load providers.env for HF_TOKEN
# ---------------------------------------------------------------------------
if [[ -f "$ENV_FILE" ]]; then
    # shellcheck source=/dev/null
    source "$ENV_FILE"
else
    echo "WARN: $ENV_FILE not found — HF_TOKEN will be empty (Gemma download will fail)"
    HF_TOKEN=""
fi

# ---------------------------------------------------------------------------
# 1. Create/update HuggingFace token secret
# ---------------------------------------------------------------------------
echo ">> [1/4] Syncing HuggingFace token secret..."
kubectl create namespace "$SIE_NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -
kubectl -n "$SIE_NAMESPACE" create secret generic sie-hf-token \
    --from-literal=HF_TOKEN="${HF_TOKEN:-}" \
    --dry-run=client -o yaml | kubectl apply -f -

# ---------------------------------------------------------------------------
# 2. Create/update custom model ConfigMaps
#    Each file in k8s/sie-models/ becomes a ConfigMap named sie-model-<basename>.
#    The ConfigMap key is "model.yaml" so the subPath mount is unambiguous.
# ---------------------------------------------------------------------------
echo ">> [2/4] Applying custom model ConfigMaps..."
MODELS_DIR="$DEPLOY_DIR/k8s/sie-models"

declare -A MODEL_MOUNT_PATHS
MODEL_MOUNT_PATHS["qwen3-14b"]="Qwen__Qwen3-14B.yaml"
MODEL_MOUNT_PATHS["qwen3-4b-2507"]="Qwen__Qwen3-4B-Instruct-2507.yaml"
MODEL_MOUNT_PATHS["qwen35-4b"]="Qwen__Qwen3.5-4B.yaml"
MODEL_MOUNT_PATHS["llama-3-70b"]="meta-llama__Llama-3.3-70B-Instruct.yaml"
MODEL_MOUNT_PATHS["gemma-4-26b"]="google__gemma-4-26B-A4B-it.yaml"

for basename in "${!MODEL_MOUNT_PATHS[@]}"; do
    src_file="$MODELS_DIR/${basename}.yaml"
    cm_name="sie-model-${basename}"
    if [[ ! -f "$src_file" ]]; then
        echo "  WARN: $src_file not found — skipping $cm_name"
        continue
    fi
    kubectl -n "$SIE_NAMESPACE" create configmap "$cm_name" \
        --from-file=model.yaml="$src_file" \
        --dry-run=client -o yaml | kubectl apply -f -
    echo "  applied $cm_name"
done

# ---------------------------------------------------------------------------
# 3. Helm install / upgrade
# ---------------------------------------------------------------------------
echo ""
echo ">> [3/4] Running helm upgrade --install sie-cluster ${SIE_CHART_VERSION}..."
helm upgrade --install sie-cluster oci://ghcr.io/superlinked/charts/sie-cluster \
    --version "$SIE_CHART_VERSION" \
    --namespace "$SIE_NAMESPACE" \
    --create-namespace \
    -f "$SCRIPT_DIR/sie-values.yaml" \
    --timeout 20m

# ---------------------------------------------------------------------------
# 4. Mount custom model configs into sie-config via JSON patch.
#    Idempotent: checks for existing volumes before patching.
# ---------------------------------------------------------------------------
echo ""
echo ">> [4/4] Mounting custom model configs into sie-config..."

kubectl -n "$SIE_NAMESPACE" rollout status deploy/sie-config --timeout=120s 2>/dev/null \
    || { echo "  WARN: sie-config not ready yet; skipping volume mounts"; exit 0; }

# Models that need mounts: basename → /app/models/<filename>
# Skip Qwen3.5-4B if the legacy qwen35-config-override volume already covers it.
ENTRIES=(
    "qwen3-14b:Qwen__Qwen3-14B.yaml"
    "qwen3-4b-2507:Qwen__Qwen3-4B-Instruct-2507.yaml"
    "llama-3-70b:meta-llama__Llama-3.3-70B-Instruct.yaml"
    "gemma-4-26b:google__gemma-4-26B-A4B-it.yaml"
)

VOLUME_PATCHES=()
MOUNT_PATCHES=()

for entry in "${ENTRIES[@]}"; do
    basename="${entry%%:*}"
    mount_filename="${entry##*:}"
    cm_name="sie-model-${basename}"
    vol_name="cm-${basename}"

    # Skip if volume already attached
    if kubectl -n "$SIE_NAMESPACE" get deployment sie-config -o json \
        | jq -e ".spec.template.spec.volumes[] | select(.name==\"$vol_name\")" >/dev/null 2>&1; then
        echo "  already mounted: $cm_name"
        continue
    fi

    VOLUME_PATCHES+=("{\"op\":\"add\",\"path\":\"/spec/template/spec/volumes/-\",\"value\":{\"name\":\"$vol_name\",\"configMap\":{\"name\":\"$cm_name\"}}}")
    MOUNT_PATCHES+=("{\"op\":\"add\",\"path\":\"/spec/template/spec/containers/0/volumeMounts/-\",\"value\":{\"name\":\"$vol_name\",\"mountPath\":\"/app/models/$mount_filename\",\"subPath\":\"model.yaml\"}}")
    echo "  queued: $cm_name → /app/models/$mount_filename"
done

if [[ ${#VOLUME_PATCHES[@]} -gt 0 ]]; then
    ALL_PATCHES="[$(IFS=,; echo "${VOLUME_PATCHES[*]},${MOUNT_PATCHES[*]}")]"
    kubectl -n "$SIE_NAMESPACE" patch deployment sie-config --type=json -p "$ALL_PATCHES"
    echo ">> Restarting sie-config to pick up new model mounts..."
    kubectl -n "$SIE_NAMESPACE" rollout restart deployment/sie-config
else
    echo "  all model mounts already in place"
fi

echo ""
echo ">> Waiting for gateway..."
kubectl -n "$SIE_NAMESPACE" rollout status deploy -l app.kubernetes.io/component=gateway \
    --timeout=300s 2>/dev/null || kubectl -n "$SIE_NAMESPACE" get pods

echo ""
echo ">> Pods:"
kubectl -n "$SIE_NAMESPACE" get pods

cat <<'EOF'

Smoke test (model loads on first request — may take several minutes):
  kubectl -n sie port-forward svc/sie-gateway 8080:8080 &
  curl -s http://localhost:8080/v1/models | python3 -c "import json,sys;[print(' -',m['id']) for m in json.load(sys.stdin)['data']]"

Register providers:
  ../providers/register-providers.sh

Or just run ../up.sh which does all of the above.
EOF
