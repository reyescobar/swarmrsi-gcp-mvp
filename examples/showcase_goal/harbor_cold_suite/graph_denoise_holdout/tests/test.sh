#!/usr/bin/env bash
# Sealed Harbor post-exit verifier: runs ONLY after agent exits and writes /logs/verifier/reward.txt
set -euo pipefail
mkdir -p /logs/verifier

python3 - << 'PY'
import importlib.util, math, random, pathlib

spec = importlib.util.spec_from_file_location("denoiser", "/app/src/denoiser.py")
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)

rng = random.Random(99991)  # Unseen holdout seed distinct from campaign evaluator
n = 160
adj = [[(i + d) % n for d in (-3, -2, -1, 1, 2, 3)] for i in range(n)]
truth = [math.cos(2.0 * math.pi * i / n) for i in range(n)]
mask = [0 if rng.random() < 0.40 else 1 for _ in range(n)]
obs = [((truth[i] + (14.0 if rng.random() < 0.10 else rng.gauss(0, 0.12))) if mask[i] else 0.0) for i in range(n)]

pred = mod.recover_signal(adj, obs, mask)
rmse = math.sqrt(sum((p - t) ** 2 for p, t in zip(pred, truth)) / n)
reward = 1.0 if rmse < 0.22 else 0.0
pathlib.Path("/logs/verifier/reward.txt").write_text(f"{reward}\n")
print(f"Holdout RMSE={rmse:.4f} -> reward={reward}")
PY
