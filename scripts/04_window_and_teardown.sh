#!/usr/bin/env bash
# Copyright 2026 Google LLC
# SPDX-License-Identifier: Apache-2.0
set -euo pipefail

ACTION="${1:---close-window}"
PROJECT_ID="${PROJECT_ID:-$(gcloud config get-value project)}"
ZONE="${ZONE:-us-central1-c}"
CLUSTER="${CLUSTER:-swarmrsi-gke}"

if [[ "${ACTION}" == "--close-window" ]]; then
  echo "=== Closing active campaign window ($0/hr bare-metal idle state) ==="
  echo "1. Synchronously suspending any RUNNING actors to GCS..."
  for actor in $(kubectl ate get actors -a swarm-mvp -o jsonpath='{.items[?(@.status.state=="RUNNING")].metadata.name}' 2>/dev/null || true); do
    kubectl ate suspend actor "${actor}" -a swarm-mvp --mode=sync
  done
  echo "2. Scaling microVM WorkerPool replicas -> 0 BEFORE resizing metal node pool..."
  kubectl patch workerpool swarm-workers-microvm -n swarm-sandboxes --type=merge -p '{"spec":{"replicas":0}}' || true
  echo "3. Scaling microvm-metal node pool -> 0 nodes..."
  gcloud container clusters resize "${CLUSTER}" --node-pool=microvm-metal --num-nodes=0 --zone="${ZONE}" --project="${PROJECT_ID}" --quiet || true
  echo "Window closed cleanly. AlloyDB Central Memory remains intact."
  exit 0
fi

if [[ "${ACTION}" == "--destroy-all" ]]; then
  echo "=== Full Teardown: Releasing Agent Substrate 500GiB PersistentDisk FIRST ==="
  TMP_ATE="$(mktemp -d)"
  git clone --depth 1 --branch v1.0.1 https://github.com/agent-substrate/substrate.git "${TMP_ATE}/substrate"
  (cd "${TMP_ATE}/substrate" && go run ./cmd/ate-setup delete ate-system) || true
  rm -rf "${TMP_ATE}"

  echo "=== Running terraform destroy ==="
  (cd infra/terraform && terraform destroy -auto-approve)
fi
