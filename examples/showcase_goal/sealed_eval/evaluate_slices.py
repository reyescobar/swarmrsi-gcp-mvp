#!/usr/bin/env python3
"""Air-gapped 4-Slice Sealed Evaluator (mounted ONLY inside Verifier, never in worker VMs)."""
from __future__ import annotations

import argparse
import hashlib
import importlib.util
import json
import math
from pathlib import Path
import random
import time


def _ring_knn_graph(n: int, k_half: int, rng: random.Random) -> tuple[list[list[int]], list[float]]:
    adj: list[list[int]] = [[] for _ in range(n)]
    truth = [math.sin(2.0 * math.pi * i / n) + 0.35 * math.cos(4.0 * math.pi * i / n) for i in range(n)]
    for i in range(n):
        for d in range(1, k_half + 1):
            j1, j2 = (i + d) % n, (i - d) % n
            adj[i].extend([j1, j2])
        extra = rng.randrange(n)
        if abs(truth[i] - truth[extra]) < 0.25 and extra != i:
            adj[i].append(extra)
    return adj, truth


def _score_rmse_to_utility(pred: list[float], truth: list[float], scale: float = 0.55) -> float:
    mse = sum((p - t) ** 2 for p, t in zip(pred, truth)) / len(truth)
    rmse = math.sqrt(mse)
    return max(0.0, min(1.0, math.exp(-rmse / scale)))


def evaluate_candidate(repo_dir: Path) -> dict[str, object]:
    mod_path = repo_dir / "src" / "denoiser.py"
    spec = importlib.util.spec_from_file_location("cand_denoiser", mod_path)
    assert spec and spec.loader
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    recover_signal = mod.recover_signal

    all_preds_rounded: list[float] = []

    # Slice 1: High sparse dropout (45% zeroed missing sensors)
    rng1 = random.Random(1001)
    adj1, truth1 = _ring_knn_graph(90, 3, rng1)
    mask1 = [0 if rng1.random() < 0.45 else 1 for _ in range(90)]
    obs1 = [(truth1[i] + rng1.gauss(0, 0.08)) if mask1[i] else 0.0 for i in range(90)]
    p1 = recover_signal(adj1, obs1, mask1)
    u_dropout = _score_rmse_to_utility(p1, truth1, scale=0.45)
    all_preds_rounded.extend(round(x, 6) for x in p1)

    # Slice 2: Smooth multi-hop dense manifold (moderate Gaussian noise, full mask)
    rng2 = random.Random(2002)
    adj2, truth2 = _ring_knn_graph(100, 4, rng2)
    mask2 = [1] * 100
    obs2 = [truth2[i] + rng2.gauss(0, 0.35) for i in range(100)]
    p2 = recover_signal(adj2, obs2, mask2)
    u_manifold = _score_rmse_to_utility(p2, truth2, scale=0.32)
    all_preds_rounded.extend(round(x, 6) for x in p2)

    # Slice 3: Heavy-tail +/-12.0 outlier burst on 12% of sensors
    rng3 = random.Random(3003)
    adj3, truth3 = _ring_knn_graph(90, 3, rng3)
    mask3 = [1] * 90
    obs3 = [
        truth3[i] + (rng3.choice([-12.0, 12.0]) if rng3.random() < 0.12 else rng3.gauss(0, 0.08))
        for i in range(90)
    ]
    p3 = recover_signal(adj3, obs3, mask3)
    u_outlier = _score_rmse_to_utility(p3, truth3, scale=0.55)
    all_preds_rounded.extend(round(x, 6) for x in p3)

    # Slice 4: Larger 180-node mixed stress test + latency bound (< 50 ms)
    rng4 = random.Random(4004)
    adj4, truth4 = _ring_knn_graph(180, 3, rng4)
    mask4 = [0 if rng4.random() < 0.25 else 1 for _ in range(180)]
    obs4 = [
        ((truth4[i] + (8.0 if rng4.random() < 0.06 else rng4.gauss(0, 0.15))) if mask4[i] else 0.0)
        for i in range(180)
    ]
    t0 = time.perf_counter()
    p4 = recover_signal(adj4, obs4, mask4)
    elapsed_ms = (time.perf_counter() - t0) * 1000.0
    lat_factor = 1.0 if elapsed_ms <= 50.0 else max(0.2, 50.0 / elapsed_ms)
    u_latency = _score_rmse_to_utility(p4, truth4, scale=0.45) * lat_factor
    all_preds_rounded.extend(round(x, 6) for x in p4)

    subtasks = {
        "slice_sparse_dropout": round(u_dropout, 6),
        "slice_dense_manifold": round(u_manifold, 6),
        "slice_outlier_burst": round(u_outlier, 6),
        "slice_latency_bound": round(u_latency, 6),
    }
    agg = round(sum(subtasks.values()) / len(subtasks), 6)
    digest = hashlib.sha256(json.dumps(all_preds_rounded).encode("utf-8")).hexdigest()

    return {
        "aggregate_utility": agg,
        "subtask_utilities": subtasks,
        "predictions_sha256": digest,
        "latency_ms": round(elapsed_ms, 3),
    }


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--repo-dir", required=True, type=Path)
    ap.add_argument("--report-out", required=True, type=Path)
    args = ap.parse_args()
    rep = evaluate_candidate(args.repo_dir)
    args.report_out.write_text(json.dumps(rep, indent=2), encoding="utf-8")


if __name__ == "__main__":
    main()
