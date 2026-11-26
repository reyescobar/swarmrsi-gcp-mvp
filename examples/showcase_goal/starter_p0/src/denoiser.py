# Copyright 2026 Google LLC
# SPDX-License-Identifier: Apache-2.0
"""Starter program p_0 for the 4-slice Graph Signal Denoising showcase.

Baseline aggregate utility u(p_0) ~= 0.44 (Target >= 0.80).
Why p_0 struggles on specific slices:
  - `slice_sparse_dropout`: Missing sensors equal 0.0 (`observed_mask[j] == 0`), pulling
    naive unweighted averages toward zero.
  - `slice_outlier_burst`: Heavy-tail sensor spikes corrupt neighbor averages without
    robust clipping / Huber weighting.
  - `slice_dense_manifold`: Single-step smoothing under-diffuses multi-hop structure.
"""
from __future__ import annotations


def recover_signal(
    adj: list[list[int]],
    noisy_obs: list[float],
    observed_mask: list[int],
) -> list[float]:
    """Recovers clean scalar node signal from noisy, partially masked observations."""
    n = len(noisy_obs)
    out = [0.0] * n
    for i in range(n):
        nbrs = adj[i]
        if not nbrs:
            out[i] = noisy_obs[i]
            continue
        # Naive baseline: 1-step unweighted mean ignoring `observed_mask` and outliers
        nbr_mean = sum(noisy_obs[j] for j in nbrs) / len(nbrs)
        out[i] = 0.5 * noisy_obs[i] + 0.5 * nbr_mean
    return out
