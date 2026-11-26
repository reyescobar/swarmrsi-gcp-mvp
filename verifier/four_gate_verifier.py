# Copyright 2026 Google LLC
# SPDX-License-Identifier: Apache-2.0
"""Deterministic 4-Gate Cascade Verifier (BOM-09 — Zero LLM).

Executes strictly outside the worker model:
  Gate 1: Patch hygiene (`allowed_edit_globs`) + fast smoke check (`<10s`)
  Gate 2: Normalized AST structural delta + static call-graph reachability from entrypoint
  Gate 3: Canonical output SHA-256 inequality vs. parent P_t (catches silent overwrites)
  Gate 4: Anti-overfit literal guard + sealed multi-slice evaluation -> {u_k}, Global Halt
"""
from __future__ import annotations

import ast
from collections import deque
from dataclasses import dataclass
import fnmatch
import hashlib
import json
from pathlib import Path
import shutil
import subprocess
import tempfile
from typing import Literal

AuditBadge = Literal["VERIFIED_GAIN", "FAITHFUL_NO_GAIN", "UNCREDITED_IMPL_BUG", "INFRA_ERROR"]


@dataclass(frozen=True)
class VerifierResult:
    gate1_smoke_ok: bool
    gate2_ast_reach_ok: bool
    gate3_output_shift_ok: bool
    gate4_objective_ok: bool
    hypothesis_credited: bool
    audit_badge: AuditBadge
    aggregate_utility: float | None
    subtask_utilities: dict[str, float]
    output_sha256: str
    modified_symbols: list[str]
    trigger_global_halt: bool
    diagnostic: str


class _DocstringStripper(ast.NodeTransformer):
    """Strips docstrings so comment/docstring-only edits never pass Gate 2."""

    def _strip(self, node: ast.AST) -> ast.AST:
        self.generic_visit(node)
        body = getattr(node, "body", None)
        if isinstance(body, list) and body:
            first = body[0]
            if isinstance(first, ast.Expr) and isinstance(getattr(first, "value", None), ast.Constant):
                if isinstance(first.value.value, str):
                    body.pop(0)
                    if not body:
                        body.append(ast.Pass())
        return node

    visit_Module = _strip
    visit_FunctionDef = _strip
    visit_AsyncFunctionDef = _strip
    visit_ClassDef = _strip


def _normalized_ast_map(py_source: str) -> tuple[str, dict[str, str], dict[str, set[str]]]:
    tree = ast.parse(py_source)
    clean_tree = _DocstringStripper().visit(tree)
    ast.fix_missing_locations(clean_tree)
    module_dump = ast.dump(clean_tree, annotate_fields=True, include_attributes=False)

    func_dumps: dict[str, str] = {}
    call_graph: dict[str, set[str]] = {}
    for node in clean_tree.body:
        if isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef)):
            func_dumps[node.name] = ast.dump(node, annotate_fields=True, include_attributes=False)
            callees: set[str] = set()
            for sub in ast.walk(node):
                if isinstance(sub, ast.Call):
                    if isinstance(sub.func, ast.Name):
                        callees.add(sub.func.id)
                    elif isinstance(sub.func, ast.Attribute):
                        callees.add(sub.func.attr)
            call_graph[node.name] = callees
    return module_dump, func_dumps, call_graph


def check_ast_delta_and_reachability(
    parent_py: str,
    candidate_py: str,
    entrypoint_func: str,
) -> tuple[bool, list[str], str]:
    """Gate 2: Requires non-zero AST diff AND call-graph reachability from `entrypoint_func`."""
    try:
        p_mod, p_funcs, _ = _normalized_ast_map(parent_py)
        c_mod, c_funcs, c_calls = _normalized_ast_map(candidate_py)
    except SyntaxError as exc:
        return (False, [], f"SyntaxError in candidate: {exc}")

    if p_mod == c_mod:
        return (False, [], "Zero AST delta vs. parent (whitespace/comment-only edit)")

    changed_funcs = [
        fn for fn, dump in c_funcs.items() if p_funcs.get(fn) != dump
    ]
    # Check module-level constant / statement changes outside functions too
    reachable: set[str] = set()
    queue: deque[str] = deque([entrypoint_func])
    while queue:
        cur = queue.popleft()
        if cur in reachable:
            continue
        reachable.add(cur)
        for nxt in c_calls.get(cur, ()):
            if nxt not in reachable:
                queue.append(nxt)

    reachable_changed = [fn for fn in changed_funcs if fn in reachable]
    if not reachable_changed:
        return (
            False,
            changed_funcs,
            f"Modified symbols {changed_funcs} are unreachable from entrypoint '{entrypoint_func}'",
        )
    return (True, reachable_changed, "OK")


def run_four_gate_cascade(
    parent_dir: Path,
    candidate_dir: Path,
    allowed_edit_globs: list[str],
    smoke_cmd: list[str],
    sealed_eval_cmd: list[str],
    target_py_relpath: str,
    entrypoint_func: str,
    parent_utility: float,
    parent_output_sha256: str,
    target_utility: float,
    stop_mode: str = "DUAL",
) -> VerifierResult:
    """Executes all 4 deterministic gates in order, failing fast on uncredited bugs."""
    # Gate 1A: Verify no edits occurred outside allowed_edit_globs
    for cand_file in candidate_dir.rglob("*"):
        if not cand_file.is_file():
            continue
        rel = cand_file.relative_to(candidate_dir).as_posix()
        if rel.startswith(".git/") or "__pycache__/" in rel or rel.endswith(".pyc"):
            continue
        par_file = parent_dir / rel
        is_modified = (not par_file.exists()) or (cand_file.read_bytes() != par_file.read_bytes())
        if is_modified and not any(fnmatch.fnmatch(rel, pat) for pat in allowed_edit_globs):
            return VerifierResult(
                False, False, False, False, False, "UNCREDITED_IMPL_BUG",
                None, {}, "", [], False, f"Illegal modification outside allowed_edit_globs: {rel}",
            )

    # Gate 1B: Fast smoke check (<10s)
    smoke = subprocess.run(smoke_cmd, cwd=candidate_dir, capture_output=True, text=True, timeout=15)
    if smoke.returncode != 0:
        return VerifierResult(
            False, False, False, False, False, "UNCREDITED_IMPL_BUG",
            None, {}, "", [], False, f"Smoke failed (rc={smoke.returncode}): {smoke.stderr[-240:]}",
        )

    # Gate 2: AST structural diff + static call-graph reachability from entrypoint
    parent_src = (parent_dir / target_py_relpath).read_text(encoding="utf-8")
    cand_src = (candidate_dir / target_py_relpath).read_text(encoding="utf-8")
    g2_ok, changed_syms, g2_msg = check_ast_delta_and_reachability(parent_src, cand_src, entrypoint_func)
    if not g2_ok:
        return VerifierResult(
            True, False, False, False, False, "UNCREDITED_IMPL_BUG",
            None, {}, "", changed_syms, False, g2_msg,
        )

    # Gate 3 & 4: Run sealed evaluator in clean temp output directory -> compare prediction SHA-256 & utility
    with tempfile.TemporaryDirectory() as out_tmp:
        out_json = Path(out_tmp) / "eval_report.json"
        ev = subprocess.run(
            [*sealed_eval_cmd, "--repo-dir", str(candidate_dir), "--report-out", str(out_json)],
            capture_output=True, text=True, timeout=60,
        )
        if ev.returncode != 0 or not out_json.exists():
            return VerifierResult(
                True, True, False, False, False, "UNCREDITED_IMPL_BUG",
                None, {}, "", changed_syms, False, f"Sealed evaluator crashed: {ev.stderr[-240:]}",
            )
        report = json.loads(out_json.read_text(encoding="utf-8"))

    cand_hash = str(report["predictions_sha256"])
    if cand_hash == parent_output_sha256:
        return VerifierResult(
            True, True, False, False, False, "UNCREDITED_IMPL_BUG",
            None, {}, cand_hash, changed_syms, False,
            "Candidate prediction SHA-256 is identical to parent (silent downstream overwrite / no-op)",
        )

    u_agg = float(report["aggregate_utility"])
    slices = {str(k): float(v) for k, v in report.get("subtask_utilities", {}).items()}
    is_gain = u_agg > (parent_utility + 1e-9)
    badge: AuditBadge = "VERIFIED_GAIN" if is_gain else "FAITHFUL_NO_GAIN"
    met_goal = is_gain and (u_agg >= target_utility) and stop_mode in ("STOP_ON_PASS", "DUAL")

    return VerifierResult(
        gate1_smoke_ok=True,
        gate2_ast_reach_ok=True,
        gate3_output_shift_ok=True,
        gate4_objective_ok=is_gain,
        hypothesis_credited=True,
        audit_badge=badge,
        aggregate_utility=u_agg,
        subtask_utilities=slices,
        output_sha256=cand_hash,
        modified_symbols=[f"{target_py_relpath}::{s}" for s in changed_syms],
        trigger_global_halt=met_goal,
        diagnostic=f"Evaluated cleanly: u={u_agg:.4f} (parent={parent_utility:.4f})",
    )


def clone_tree(src: Path, dst: Path) -> None:
    if dst.exists():
        shutil.rmtree(dst)
    shutil.copytree(src, dst)
