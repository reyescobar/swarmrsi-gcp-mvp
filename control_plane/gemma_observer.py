# Copyright 2026 Google LLC
# SPDX-License-Identifier: Apache-2.0
"""Cross-Family Gemma 3 Batch Observer & Deterministic Phase-3 Maxim Write Gate."""
from __future__ import annotations

from dataclasses import dataclass
import re
from typing import Literal

_SECRET_AND_PATH_REGEX = re.compile(
    r"(SWARM_CANARY_[A-Za-z0-9_]+|AIza[0-9A-Za-z\-_]{20,}|ya29\.[0-9A-Za-z\-_]+|"
    r"(?:^|\s)(?:src|app|tests|workspace)/[\w./-]+|\b\w+\.(?:py|ts|js|go|sql|yaml)\b)",
    flags=re.IGNORECASE,
)


@dataclass(frozen=True)
class TrialAuditRecord:
    trial_id: str
    hypothesis_id: str
    audit_badge: Literal["VERIFIED_GAIN", "FAITHFUL_NO_GAIN", "UNCREDITED_IMPL_BUG", "INFRA_ERROR"]


@dataclass(frozen=True)
class MaximProposal:
    polarity: Literal["DO", "AVOID"]
    maxim_claim: str
    when_applies: str
    when_not_to_apply: str
    evidence_trial_ids: tuple[str, ...]
    domain_tags: tuple[str, ...] = ()


def enforce_pass2_attribution_rules(
    directive: str,
    uncredited_bug_count: int,
    faithful_nogain_count: int,
    best_matching_fp_base: str | None,
) -> str:
    """Hard Harness override on Gemma Pass 2: NEVER retire an idea due to UNCREDITED_IMPL_BUG."""
    if uncredited_bug_count >= 1 and faithful_nogain_count < 2:
        if directive == "RETIRE_AND_BRANCH":
            return "REBASE_HYPOTHESIS" if best_matching_fp_base else "CONTINUE_LINEAGE"
    return directive


def validate_portable_maxim(
    proposal: MaximProposal,
    trial_ledger: dict[str, TrialAuditRecord],
    repo_forbidden_tokens: list[str],
) -> tuple[bool, str]:
    """Phase-3 Deterministic Post-Gemma Gatekeeper (Citation + Precondition + Leak Scanner).

    Returns (accepted: bool, rejection_reason_or_OK: str).
    """
    if not proposal.when_applies.strip() or not proposal.when_not_to_apply.strip():
        return (False, "MISSING_COUNTER_INDICATION_WHEN_NOT_TO_APPLY")

    if not proposal.evidence_trial_ids:
        return (False, "EMPTY_EVIDENCE_CITATIONS")

    badges = []
    for tid in proposal.evidence_trial_ids:
        rec = trial_ledger.get(tid)
        if rec is None:
            return (False, f"UNKNOWN_TRIAL_CITATION:{tid}")
        if rec.audit_badge in ("UNCREDITED_IMPL_BUG", "INFRA_ERROR"):
            return (False, f"UNCREDITED_TRIAL_CANNOT_SUPPORT_MAXIM:{tid}")
        badges.append(rec.audit_badge)

    if proposal.polarity == "DO" and "VERIFIED_GAIN" not in badges:
        return (False, "DO_MAXIM_REQUIRES_VERIFIED_GAIN")
    if proposal.polarity == "AVOID" and badges.count("FAITHFUL_NO_GAIN") < 2:
        return (False, "AVOID_MAXIM_REQUIRES_TWO_FAITHFUL_NOGAIN_TRIALS")

    combined_text = f"{proposal.maxim_claim} {proposal.when_applies} {proposal.when_not_to_apply}"
    m = _SECRET_AND_PATH_REGEX.search(combined_text)
    if m:
        return (False, f"LEAKED_PATH_OR_CANARY:{m.group(0).strip()}")

    lowered = combined_text.lower()
    for tok in repo_forbidden_tokens:
        if tok and tok.lower() in lowered:
            return (False, f"LEAKED_REPO_FORBIDDEN_TOKEN:{tok}")

    return (True, "OK")


def update_maxim_survival_counters(
    hit_count: int,
    attempt_count: int,
    current_status: str,
    trial_audit_badge: str,
) -> tuple[int, int, str]:
    """Harness-owned empirical survival loop (Section 4.2 Phase 3)."""
    if trial_audit_badge in ("UNCREDITED_IMPL_BUG", "INFRA_ERROR"):
        return (hit_count, attempt_count, current_status)
    if trial_audit_badge == "VERIFIED_GAIN":
        nh, na = hit_count + 1, attempt_count + 1
        next_status = "ACTIVE" if nh >= 2 else current_status
        return (nh, na, next_status)
    if trial_audit_badge == "FAITHFUL_NO_GAIN":
        nh, na = hit_count, attempt_count + 1
        next_status = "DEPRECATED" if (na >= 4 and (nh / na) < 0.25) else current_status
        return (nh, na, next_status)
    return (hit_count, attempt_count, current_status)
