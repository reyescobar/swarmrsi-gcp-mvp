# Copyright 2026 Google LLC
# SPDX-License-Identifier: Apache-2.0
"""SwarmRSI Discounted-UCB Scheduler, Donor Selector & Prefix-Cached Brief Renderer.

Implements Algorithm 1, Eq. (5)-(10), and Table 5 of arXiv:2610.20431v3 without
delegating scheduling or attribution decisions to an LLM.
"""
from __future__ import annotations

from dataclasses import dataclass
import json
import math
from typing import Literal

Frontier = Literal["H", "P"]
Operator = Literal["H_MUTATE", "P_MUTATE", "REBASE", "CROSSOVER"]

# Verified SwarmRSI Table 5 Constants
RHO: float = 0.9
BETA: float = 0.5
GAMMA: float = 0.25
K_SAT: int = 4
W_WAIT: int = 8
COST_UNIT_TOKENS: float = 1000.0


@dataclass(frozen=True)
class FrontierRow:
    kind: Frontier
    n: float
    gain: float
    cost: float
    wait_steps: int
    open_needs: int
    feasible: bool
    has_sample: bool


@dataclass(frozen=True)
class ProgramCandidate:
    program_id: str
    aggregate_utility: float
    subtask_utilities: dict[str, float]
    mechanism_labels: tuple[str, ...] = ()
    summary: str = ""


def wilson_lower_bound(hits: int, attempts: int, z: float = 1.96) -> float:
    """95% Wilson score lower bound for ranking General Maxims empirically."""
    if attempts <= 0 or hits < 0 or hits > attempts:
        return 0.0
    p = hits / attempts
    z2 = z * z
    denom = 1.0 + z2 / attempts
    center = p + z2 / (2.0 * attempts)
    spread = z * math.sqrt((p * (1.0 - p) + z2 / (4.0 * attempts)) / attempts)
    return max(0.0, (center - spread) / denom)


def score_frontier(row: FrontierRow, n_total: float) -> float:
    """SwarmRSI Eq. (6): S_f = mu_hat_f + beta * sqrt(ln(1 + N_H + N_P) / N_f) + gamma * psi_f."""
    mu_hat = row.gain / max(row.cost, 1e-9)
    explore = BETA * math.sqrt(math.log(1.0 + n_total) / max(row.n, 1e-9))
    psi = min(row.open_needs, K_SAT) / float(K_SAT)
    return mu_hat + explore + GAMMA * psi


def select_next_frontier(h: FrontierRow, p: FrontierRow) -> Frontier:
    """Priority & Discounted-UCB frontier controller (arXiv:2610.20431 Section A.1)."""
    if h.feasible and not p.feasible:
        return "H"
    if p.feasible and not h.feasible:
        return "P"
    if not h.has_sample:
        return "H"
    if not p.has_sample:
        return "P"
    if h.wait_steps >= W_WAIT and h.wait_steps >= p.wait_steps:
        return "H"
    if p.wait_steps >= W_WAIT:
        return "P"
    n_tot = h.n + p.n
    sh, sp = score_frontier(h, n_tot), score_frontier(p, n_tot)
    if abs(sh - sp) > 1e-9:
        return "H" if sh > sp else "P"
    if abs(h.n - p.n) > 1e-9:
        return "H" if h.n < p.n else "P"
    return "H"


def update_ucb_after_trial(
    rows: dict[Frontier, FrontierRow],
    chosen: Frontier,
    u_trial: float | None,
    u_prev_incumbent: float | None,
    uncached_tokens_tau: int,
    hypothesis_credited: bool,
    is_infra_error: bool,
    scale_s: float = 1.0,
) -> dict[Frontier, tuple[float, float, float, int]]:
    """SwarmRSI Eq. (7)-(8): Infra errors leave UCB stats unchanged."""
    if is_infra_error:
        return {k: (r.n, r.gain, r.cost, r.wait_steps) for k, r in rows.items()}
    if (not hypothesis_credited) or u_trial is None or u_prev_incumbent is None:
        r_t = 0.0
    else:
        r_t = min(1.0, max(0.0, (u_trial - u_prev_incumbent) / max(scale_s, 1e-9)))
    c_t = max(1.0, uncached_tokens_tau / COST_UNIT_TOKENS)
    updated: dict[Frontier, tuple[float, float, float, int]] = {}
    for k, r in rows.items():
        hit = 1.0 if k == chosen else 0.0
        next_wait = 0 if k == chosen else (r.wait_steps + (1 if r.feasible else 0))
        updated[k] = (RHO * r.n + hit, RHO * r.gain + hit * r_t, RHO * r.cost + hit * c_t, next_wait)
    return updated


def select_crossover_donors(
    parent: ProgramCandidate,
    frontier_fp: list[ProgramCandidate],
    min_slice_margin: float = 0.02,
    max_donors: int = 2,
) -> dict[str, str]:
    """SwarmRSI Eq. (5) & (10): Per-slice donor ownership map sigma_t(k).

    Returns {slice_name: donor_program_id} for slices where a frontier donor
    strictly outperforms `parent` by at least `min_slice_margin`, capped at `max_donors`.
    """
    if len(parent.subtask_utilities) < 2:
        return {}
    donor_gains: dict[str, tuple[float, list[tuple[str, float]]]] = {}
    for cand in frontier_fp:
        if cand.program_id == parent.program_id:
            continue
        wins: list[tuple[str, float]] = []
        for s_key, p_val in parent.subtask_utilities.items():
            d_val = cand.subtask_utilities.get(s_key)
            if d_val is not None and (d_val - p_val) >= min_slice_margin:
                wins.append((s_key, d_val))
        if wins:
            total_lift = sum(d_val - parent.subtask_utilities[s_key] for s_key, d_val in wins)
            donor_gains[cand.program_id] = (total_lift, wins)

    top_donor_ids = [
        did for did, _ in sorted(donor_gains.items(), key=lambda kv: kv[1][0], reverse=True)[:max_donors]
    ]
    if not top_donor_ids:
        return {}

    slice_owner: dict[str, tuple[str, float]] = {}
    for did in top_donor_ids:
        for s_key, d_val in donor_gains[did][1]:
            cur = slice_owner.get(s_key)
            if cur is None or d_val > cur[1]:
                slice_owner[s_key] = (did, d_val)
    return {s_key: owner_id for s_key, (owner_id, _) in slice_owner.items()}


def render_task_brief(
    goal_markdown: str,
    allowed_edit_globs: list[str],
    smoke_cmd: str,
    goal_facts: list[str],
    general_maxims: list[str],
    operator: Operator,
    lease_id: str,
    mechanism_family: str,
    operator_details: dict[str, object],
    max_local_attempts: int = 4,
) -> str:
    """Renders Block A (frozen campaign prefix for >75% Gemini cache hit) + Block B suffix."""
    globs_csv = ", ".join(allowed_edit_globs)
    facts_md = "\n".join(f"- {f}" for f in goal_facts) if goal_facts else "- (Round 1 cold start — no prior goal facts yet)"
    maxims_md = "\n".join(f"- {m}" for m in general_maxims) if general_maxims else "- (No portable maxims matched yet)"
    details_json = json.dumps(operator_details, indent=2, sort_keys=True)

    return (
        "<!-- BLOCK A: FROZEN CAMPAIGN PREFIX -->\n"
        f"# Campaign Objective\n{goal_markdown.strip()}\n\n"
        "## Sandbox Execution Rules (Enforced Deterministically Outside Model)\n"
        f"- Editable paths (`allowed_edit_globs`): {globs_csv}\n"
        f"- Local smoke command (`max {max_local_attempts}` runs): `{smoke_cmd}`\n"
        "- Never modify evaluation harnesses, fixtures, or `/workspace/donors/`.\n"
        "- Before finishing, write `/workspace/candidate_claim.json`:\n"
        '  `{"declared_success": true, "mechanism_summary": "...", "edited_symbols": ["..."]}`\n\n'
        "---\n<!-- BLOCK B: PER-LEASE DYNAMIC SUFFIX -->\n"
        f"## Verified Goal Memory\n{facts_md}\n\n"
        f"## Validated General Maxims\n{maxims_md}\n\n"
        f"## Assigned Operator: `{operator}` (Lease `{lease_id}`, Family `{mechanism_family}`)\n"
        f"```json\n{details_json}\n```\n"
    )
