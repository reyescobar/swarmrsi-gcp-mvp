#!/usr/bin/env bash
# Copyright 2026 Google LLC
# SPDX-License-Identifier: Apache-2.0
set -euo pipefail

# Runs an end-to-end local simulation of the 4-slice SwarmRSI campaign + 4-Gate Verifier +
# Crossover Donor Recombination + Global Halt + Gemma Maxim Gate + Cold Harbor Check right out of the box!
PYTHONPATH=. python3 - << 'PY'
from pathlib import Path
import sys
import tempfile

from control_plane.blackboard_valve import synthesize_blackboard_entry
from control_plane.gemma_observer import MaximProposal, TrialAuditRecord, validate_portable_maxim
from control_plane.ucb_scheduler import (
    FrontierRow, ProgramCandidate, select_crossover_donors, select_next_frontier, update_ucb_after_trial
)
from meta_loop.swarm_harbor_agent import evaluate_cold_promotion_gate
from verifier.four_gate_verifier import clone_tree, run_four_gate_cascade
from examples.showcase_goal.sealed_eval.evaluate_slices import evaluate_candidate

ROOT = Path("examples/showcase_goal")
STARTER = ROOT / "starter_p0"
EVAL_SCRIPT = ROOT / "sealed_eval" / "evaluate_slices.py"

base_rep = evaluate_candidate(STARTER)
u0 = float(base_rep["aggregate_utility"])
h0 = str(base_rep["predictions_sha256"])
print(f"[C1 Baseline] Starter p_0 utility u={u0:.4f}, slices={base_rep['subtask_utilities']}")

with tempfile.TemporaryDirectory() as tmp:
    tmp_p = Path(tmp)

    # Trial 1: Planted dead-code bug -> caught by Gate 2 -> UNCREDITED_IMPL_BUG (Hypothesis kept alive!)
    t1_dir = tmp_p / "trial1_dead_code"
    clone_tree(STARTER, t1_dir)
    src = (t1_dir / "src/denoiser.py").read_text()
    (t1_dir / "src/denoiser.py").write_text(src + "\ndef unused_helper(x):\n    return x * 2.0\n")
    r1 = run_four_gate_cascade(
        STARTER, t1_dir, ["src/*.py"], [sys.executable, "smoke_check.py"],
        [sys.executable, str(EVAL_SCRIPT)], "src/denoiser.py", "recover_signal", u0, h0, 0.80,
    )
    print(f"[Round 1 · VM-1] Planted dead-code audit -> badge={r1.audit_badge}, credited={r1.hypothesis_credited} ({r1.diagnostic})")

    # Trial 2 (Donor A): Masked dropout-aware diffusion -> wins slice_sparse_dropout & slice_dense_manifold
    t2_dir = tmp_p / "trial2_masked_diffusion"
    clone_tree(STARTER, t2_dir)
    (t2_dir / "src/denoiser.py").write_text('''
def recover_signal(adj, noisy_obs, observed_mask):
    cur = list(noisy_obs)
    for _ in range(3):
        nxt = [0.0] * len(cur)
        for i, nbrs in enumerate(adj):
            vals = [cur[j] for j in nbrs if observed_mask[j]]
            nbr_est = (sum(vals) / len(vals)) if vals else cur[i]
            nxt[i] = (0.45 * cur[i] + 0.55 * nbr_est) if observed_mask[i] else nbr_est
        cur = nxt
    return cur
''')
    r2 = run_four_gate_cascade(
        STARTER, t2_dir, ["src/*.py"], [sys.executable, "smoke_check.py"],
        [sys.executable, str(EVAL_SCRIPT)], "src/denoiser.py", "recover_signal", u0, h0, 0.80,
    )
    print(f"[Round 1 · VM-2] Masked diffusion -> badge={r2.audit_badge}, u={r2.aggregate_utility:.4f}, slices={r2.subtask_utilities}")

    # Trial 3 (Donor B): Median-clipped outlier suppressor -> wins slice_outlier_burst
    t3_dir = tmp_p / "trial3_outlier_clip"
    clone_tree(STARTER, t3_dir)
    (t3_dir / "src/denoiser.py").write_text('''
def _median(xs):
    s = sorted(xs)
    m = len(s) // 2
    return s[m] if len(s) % 2 else 0.5 * (s[m - 1] + s[m])

def recover_signal(adj, noisy_obs, observed_mask):
    out = [0.0] * len(noisy_obs)
    for i, nbrs in enumerate(adj):
        med = _median([noisy_obs[j] for j in nbrs] + [noisy_obs[i]])
        self_v = noisy_obs[i] if abs(noisy_obs[i] - med) < 2.0 else med
        out[i] = 0.4 * self_v + 0.6 * med
    return out
''')
    r3 = run_four_gate_cascade(
        STARTER, t3_dir, ["src/*.py"], [sys.executable, "smoke_check.py"],
        [sys.executable, str(EVAL_SCRIPT)], "src/denoiser.py", "recover_signal", u0, h0, 0.80,
    )
    print(f"[Round 1 · VM-3] Outlier median clip -> badge={r3.audit_badge}, u={r3.aggregate_utility:.4f}, slices={r3.subtask_utilities}")

    # SwarmRSI Crossover Donor Selection (Eq. 5 & 10)
    cand_a = ProgramCandidate("prog_A", r2.aggregate_utility or 0.0, r2.subtask_utilities)
    cand_b = ProgramCandidate("prog_B", r3.aggregate_utility or 0.0, r3.subtask_utilities)
    donor_map = select_crossover_donors(cand_a, [cand_a, cand_b])
    print(f"[Round 2 · C5 Crossover] Complementary slice donor map for parent prog_A -> {donor_map}")

    # Trial 4 (Crossover Child): Combines masked observed propagation (A) + median spike rejection (B) -> GLOBAL HALT!
    t4_dir = tmp_p / "trial4_crossover_winner"
    clone_tree(STARTER, t4_dir)
    (t4_dir / "src/denoiser.py").write_text('''
def _median(xs):
    s = sorted(xs)
    m = len(s) // 2
    return s[m] if len(s) % 2 else 0.5 * (s[m - 1] + s[m])

def recover_signal(adj, noisy_obs, observed_mask):
    n = len(noisy_obs)
    # Pass 1: Despike observed nodes via observed-neighbor median
    clean = [0.0] * n
    known = [bool(m) for m in observed_mask]
    for i in range(n):
        obs_nbrs = [noisy_obs[j] for j in adj[i] if known[j]]
        ref = _median(obs_nbrs) if obs_nbrs else 0.0
        if known[i] and abs(noisy_obs[i] - ref) <= 2.2:
            clean[i] = noisy_obs[i]
        else:
            clean[i] = ref
            known[i] = bool(obs_nbrs)
    # Pass 2: Confidence-weighted diffusion smoothing Gaussian noise while imputing dropouts
    cur = list(clean)
    for _ in range(4):
        nxt = [0.0] * n
        for i, nbrs in enumerate(adj):
            nbr_mean = sum(cur[j] for j in nbrs) / len(nbrs)
            is_trusted_obs = bool(observed_mask[i]) and abs(noisy_obs[i] - clean[i]) < 1e-6
            nxt[i] = (0.22 * clean[i] + 0.78 * nbr_mean) if is_trusted_obs else nbr_mean
        cur = nxt
    return cur
''')
    r4 = run_four_gate_cascade(
         t2_dir, t4_dir, ["src/*.py"], [sys.executable, "smoke_check.py"],
        [sys.executable, str(EVAL_SCRIPT)], "src/denoiser.py", "recover_signal",
        r2.aggregate_utility or u0, r2.output_sha256, 0.75,
    )
    kind, mod_state, bb_card = synthesize_blackboard_entry(
        r4.audit_badge, "CROSSOVER", (r4.aggregate_utility or 0.0) - (r2.aggregate_utility or 0.0),
        r4.modified_symbols, r4.subtask_utilities, r4.diagnostic, "prog_winner",
    )
    print(f"[Round 2 · Crossover Result] u={r4.aggregate_utility:.4f} >= 0.75 -> GLOBAL_HALT={r4.trigger_global_halt}!")
    print(f"[C4 Blackboard ({mod_state})] {bb_card}")

    # Gemma Phase-3 Portable Maxim Gate + Cold Harbor Gate Check
    ledger = {"tr_4": TrialAuditRecord("tr_4", "hyp_xover", "VERIFIED_GAIN")}
    maxim = MaximProposal(
        polarity="DO",
        maxim_claim="Pre-filter heavy-tail sensor spikes with masked local medians prior to multi-hop graph diffusion.",
        when_applies="Graph or spatial signals with simultaneous missing masks and heavy-tail impulse noise.",
        when_not_to_apply="Binary classification graphs or unweighted shortest-path routing.",
        evidence_trial_ids=("tr_4",),
    )
    ok, msg = validate_portable_maxim(maxim, ledger, ["src/denoiser.py", "recover_signal"])
    print(f"[C6 Gemma Phase-3 Gate] Portable General Maxim accepted={ok} ({msg})")

    cold_gate = evaluate_cold_promotion_gate(
        {"t1": 0.44, "t2": 0.46, "t3": 0.41, "t4": 0.45},
        {"t1": 0.86, "t2": 0.88, "t3": 0.84, "t4": 0.87},
        n_samples_per_task=1,
    )
    print(f"[C7+C8 Cold Harbor Gate (n_samples=1)] status={cold_gate.status} ({cold_gate.reason})")
PY
