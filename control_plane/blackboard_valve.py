"""Harness-Only Blackboard Entry Synthesizer, Speculation Valve & Round Barrier."""
from __future__ import annotations

from dataclasses import dataclass
import re
import statistics
from typing import Literal

ModerationState = Literal[
    "PUBLISHED_IMMEDIATE",
    "PUBLISHED_MODERATED",
    "HELD_ANTI_CONVERGENCE",
]

_INJECTION_PATTERNS = re.compile(
    r"(<\|.*?\|>|IGNORE\s+ALL\s+PREVIOUS|SYSTEM\s*:|ASSISTANT\s*:|https?://\S+)",
    flags=re.IGNORECASE,
)


def sanitize_worker_note(raw: str, max_len: int = 240) -> str:
    """Strips prompt-injection delimiters, control chars, and URLs from worker notes."""
    cleaned = _INJECTION_PATTERNS.sub("[REDACTED]", raw)
    cleaned = re.sub(r"[\x00-\x1f\x7f]+", " ", cleaned).strip()
    return cleaned[:max_len]


def synthesize_blackboard_entry(
    audit_badge: str,
    operator: str,
    utility_delta: float | None,
    edited_symbols: list[str],
    subtask_deltas: dict[str, float],
    diagnostic_tail: str,
    program_id: str | None = None,
) -> tuple[str, ModerationState, str]:
    """Builds a deterministic Blackboard entry strictly from Verifier outputs (Invariant I5)."""
    delta_str = f"{utility_delta:+.3f} u" if utility_delta is not None else "n/a"
    syms = ", ".join(edited_symbols[:4]) if edited_symbols else "no-reachable-symbol"
    slice_parts = [f"{k} ({v:+.3f})" for k, v in sorted(subtask_deltas.items())[:4]]
    slice_str = ", ".join(slice_parts) if slice_parts else "no-slice-shift"
    safe_diag = sanitize_worker_note(diagnostic_tail, max_len=220)

    if audit_badge == "VERIFIED_GAIN":
        body = (
            f"[VERIFIED_GAIN | {delta_str} | {operator}] Edited {syms}; "
            f"slice shifts: {slice_str}. Program ref: {program_id or 'pending'}."
        )
        return ("finding", "PUBLISHED_IMMEDIATE", body[:2048])

    body = (
        f"[{audit_badge} | {delta_str} | {operator}] Edited {syms}; "
        f"slices: {slice_str}. Diagnostic: {safe_diag}"
    )
    return ("failure", "PUBLISHED_IMMEDIATE", body[:2048])


def moderate_speculative_idea(
    proposed_text: str,
    max_cosine_to_existing: float,
    speculation_quota_rem: int,
) -> tuple[ModerationState | None, int, str]:
    """Two-speed anti-convergence valve (Invariant I6).

    Returns (moderation_state_or_None_if_duplicate, new_quota_rem, sanitized_body).
    """
    clean = sanitize_worker_note(proposed_text, max_len=360)
    if not clean or max_cosine_to_existing >= 0.86:
        return (None, speculation_quota_rem, "")
    if speculation_quota_rem > 0:
        return ("PUBLISHED_MODERATED", speculation_quota_rem - 1, clean)
    return ("HELD_ANTI_CONVERGENCE", 0, clean)


@dataclass(frozen=True)
class LeaseProgress:
    lease_id: str
    finished: bool
    duration_sec: float
    lease_ttl_sec: float = 1500.0


def should_close_round_barrier(leases: list[LeaseProgress], elapsed_sec: float) -> tuple[bool, list[str]]:
    """75% straggler-bounded round barrier so 1 hung VM cannot block Gemma Observer (Invariant I9)."""
    if not leases:
        return (True, [])
    if all(l.finished for l in leases):
        return (True, [])
    finished_durations = [l.duration_sec for l in leases if l.finished]
    quorum = math.ceil_75(len(leases))
    if len(finished_durations) >= quorum:
        med = statistics.median(finished_durations)
        tightened_cap = min(min(l.lease_ttl_sec for l in leases), max(180.0, 1.5 * med))
        if elapsed_sec >= tightened_cap:
            reclaimed = [l.lease_id for l in leases if not l.finished]
            return (True, reclaimed)
    return (False, [])


def math_ceil_75(n: int) -> int:
    return (3 * n + 3) // 4


# Alias used inside should_close_round_barrier
class math:  # noqa: N801 - compact local helper namespace
    ceil_75 = staticmethod(math_ceil_75)
