#!/usr/bin/env bash
set -euo pipefail

MODE="${1:---all}"
PROJECT_ID="${PROJECT_ID:-$(gcloud config get-value project)}"
REGION="${REGION:-us-central1}"
AR_REPO="${REGION}-docker.pkg.dev/${PROJECT_ID}/swarmrsi-local"

if [[ "${MODE}" == "--all" || "${MODE}" == "--images-only" ]]; then
  echo "=== Building & pushing Control Plane, 4-Gate Verifier, pi-mono Guest & Harbor MicroVM images ==="
  gcloud builds submit . --tag "${AR_REPO}/control-plane:latest" --file control_plane/Dockerfile --project "${PROJECT_ID}"
  gcloud builds submit . --tag "${AR_REPO}/verifier:latest"      --file verifier/Dockerfile      --project "${PROJECT_ID}"
  gcloud builds submit . --tag "${AR_REPO}/pimono-guest:v1"      --file guest_pimono/Dockerfile  --project "${PROJECT_ID}"
  gcloud builds submit . --tag "${AR_REPO}/harbor-microvm:v1"    --file meta_loop/Dockerfile.harbor_microvm --project "${PROJECT_ID}"
fi

if [[ "${MODE}" == "--all" || "${MODE}" == "--db-and-templates" ]]; then
  echo "=== Uploading sealed 4-slice evaluator to IAM-isolated sealed-evals bucket ==="
  gcloud storage cp -r examples/showcase_goal/sealed_eval/* "gs://${PROJECT_ID}-swarmrsi-sealed-evals/graph-signal-denoising-4slice/"

  echo "=== Resolving @sha256 digests and registering Agent Substrate ActorTemplates ==="
  PIMONO_IMAGE_DIGEST="$(gcloud artifacts docker images describe "${AR_REPO}/pimono-guest:v1" --format='value(image_summary.digest)')"
  HARBOR_IMAGE_DIGEST="$(gcloud artifacts docker images describe "${AR_REPO}/harbor-microvm:v1" --format='value(image_summary.digest)')"
  export PROJECT_ID REGION PIMONO_IMAGE_DIGEST HARBOR_IMAGE_DIGEST
  envsubst '${PROJECT_ID} ${REGION} ${PIMONO_IMAGE_DIGEST} ${HARBOR_IMAGE_DIGEST}' < substrate/actor-templates.yaml > /tmp/rendered-templates.yaml
  kubectl ate create actor-template -f /tmp/rendered-templates.yaml
  rm -f /tmp/rendered-templates.yaml

  echo "=== Schema ready: apply sql/001_swarm_schema.sql inside VPC via psql to AlloyDB primary ==="
fi
