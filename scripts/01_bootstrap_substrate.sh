#!/usr/bin/env bash
set -euo pipefail

PROJECT_ID="${PROJECT_ID:-$(gcloud config get-value project)}"
REGION="${REGION:-us-central1}"
ZONE="${ZONE:-us-central1-c}"
CLUSTER="${CLUSTER:-swarmrsi-gke}"

echo "=== [1/4] Fetching GKE credentials for ${CLUSTER} (${ZONE}) ==="
gcloud container clusters get-credentials "${CLUSTER}" --zone "${ZONE}" --project "${PROJECT_ID}"

# Detect whether the bare-metal KVM node pool exists on this cluster
if gcloud container node-pools list --cluster "${CLUSTER}" --zone "${ZONE}" --project "${PROJECT_ID}" --format="value(name)" | grep -qx "microvm-metal"; then
  SANDBOX_CLASSES="gvisor,microvm"
else
  SANDBOX_CLASSES="gvisor"
  echo "[Day-1 Mode] Bare-metal pool disabled -> deploying Agent Substrate on gVisor (zero special quota)."
fi

echo "=== [2/4] Cloning & deploying Agent Substrate v1.0.1 (${SANDBOX_CLASSES}) ==="
TMP_ATE="$(mktemp -d)"
git clone --depth 1 --branch v1.0.1 https://github.com/agent-substrate/substrate.git "${TMP_ATE}/substrate"
(
  cd "${TMP_ATE}/substrate"
  go run ./cmd/ate-setup deploy ate-system \
    --sandbox-classes="${SANDBOX_CLASSES}" \
    --image-registry="${REGION}-docker.pkg.dev/${PROJECT_ID}/swarmrsi-ghcr-mirror/agent-substrate/substrate" \
    --snapshot-bucket="${PROJECT_ID}-swarmrsi-snapshots" \
    --asset-bucket="${PROJECT_ID}-swarmrsi-snapshots-assets" \
    --ingress-allowed-spiffe-ids="spiffe://${PROJECT_ID}.svc.id.goog/ns/harness/sa/broker,spiffe://cluster.local/ns/ate-system/sa/atenet-client"
)
rm -rf "${TMP_ATE}"

echo "=== [3/4] Applying WorkerPools & Unified Control Plane ==="
ALLOYDB_HOST="$(cd infra/terraform && terraform output -raw alloydb_private_ip)"
export PROJECT_ID REGION ALLOYDB_HOST
envsubst '${PROJECT_ID} ${REGION} ${ALLOYDB_HOST}' < substrate/workerpools.yaml | kubectl apply -f -

echo "=== [4/4] Creating swarm-mvp Atespace & granting Broker editor access ==="
kubectl ate create atespace swarm-mvp || true
kubectl ate set-access-policy atespace swarm-mvp \
  --editor="user:system:serviceaccount:harness:broker"
echo "Agent Substrate v1.0.1 bootstrap complete!"
