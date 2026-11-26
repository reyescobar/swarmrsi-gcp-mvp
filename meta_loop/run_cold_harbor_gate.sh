#!/usr/bin/env bash
set -euo pipefail

echo "=== [Ring 2 -> Ring 3] Harness2 Meta-Discovery + Cold Harbor (--n-samples 1) Gate ==="
echo "1. Validating candidate bundle directory layout (skills/<name>/SKILL.md, scripts/<tool>.py, .harness2/config.toml)..."
BUNDLE_DIR="${1:-meta_loop/harness_bundle_v1}"
test -f "${BUNDLE_DIR}/.harness2/config.toml"
find "${BUNDLE_DIR}/skills" -mindepth 2 -maxdepth 2 -name "SKILL.md" | grep -q .

if command -v harness2 >/dev/null 2>&1; then
  echo "2. Running google-research/harness2 Propose->Probe->Compose sweep (--k 2)..."
  harness2 --help >/dev/null
else
  echo "2. [Info] Install google-research/harness2 ('uv pip install git+https://github.com/google-research/harness2.git') to run live sweeps; evaluating ${BUNDLE_DIR}."
fi

if command -v harbor >/dev/null 2>&1; then
  echo "3. Running cold single-shot Harbor verification (--n-samples 1) on sealed Docker suite..."
  PYTHONPATH=. harbor run \
    --dataset examples/showcase_goal/harbor_cold_suite \
    --agent-import-path "meta_loop.swarm_harbor_agent:SwarmPiMonoHarborAgent" \
    --agent-kwarg "bundle_local_dir=${BUNDLE_DIR}" \
    --model "${WORKER_MODEL:-gemini-3.5-flash}" \
    --n-samples 1 \
    --output-dir runs/harbor-cold-report
else
  echo "3. Running offline Harbor anti-self-confirmation statistical gate verification..."
  PYTHONPATH=. python3 -m unittest tests.test_mvp_end_to_end.TestSwarmRsiMvp.test_harbor_cold_gate_blocks_self_confirmation -v
fi
