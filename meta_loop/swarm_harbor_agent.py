# Copyright 2026 Google LLC
# SPDX-License-Identifier: Apache-2.0
"""Harbor Cold Single-Shot Agent Adapter & Anti-Self-Confirmation Promotion Gate.

Pairs `google-research/harness2` (Ring 2 generator) with `harbor-framework/harbor`
(Ring 3 cold falsifier at `--n-samples 1` inside an Agent Substrate microVM).
"""
from __future__ import annotations

from dataclasses import dataclass
import math
import shlex
import statistics
from typing import Any

try:
    from harbor.agents.installed.base import BaseInstalledAgent, ExecInput  # type: ignore
except ImportError:
    # Lightweight shim so local unit tests run without requiring Harbor installed globally
    @dataclass
    class ExecInput:  # type: ignore[no-redef]
        command: str
        timeout_sec: int = 900

    class BaseInstalledAgent:  # type: ignore[no-redef]
        def __init__(self, model_name: str = "gemini-3.5-flash", **kwargs: Any) -> None:
            self.model_name = model_name
            self.kwargs = kwargs


class SwarmPiMonoHarborAgent(BaseInstalledAgent):
    """Wraps frozen pi-mono + candidate Harness2 bundle for cold 1-run Harbor checks."""

    @staticmethod
    def name() -> str:
        return "swarm-pimono-bundle"

    async def setup(self, environment: Any) -> None:
        await environment.upload_dir(self.kwargs["bundle_local_dir"], "/opt/swarm/bundle")
        await environment.exec("chmod -R a-w /opt/swarm/bundle && chmod -R a+rx /opt/swarm/bundle/scripts")

    def create_run_agent_commands(self, instruction: str) -> list[ExecInput]:
        # Strictly 1 cold shot per task: Harness2 online probing OFF, Gemma writes OFF
        prompt = shlex.quote(
            "Consult /opt/swarm/bundle/skills/ and CLI tools in /opt/swarm/bundle/scripts/.\n\n"
            f"Task Instruction:\n{instruction}"
        )
        cmd = (
            "export PATH=/opt/swarm/bundle/scripts:$PATH "
            "PI_CODING_AGENT_DIR=/tmp/pi-cold-eval && "
            "mkdir -p /tmp/pi-cold-eval/extensions && "
            "cp -f /opt/swarm/bundle/extensions/swarm-guardrail.ts /tmp/pi-cold-eval/extensions/ 2>/dev/null || true && "
            f"pi --provider swarm-broker --model {shlex.quote(self.model_name)} --print {prompt}"
        )
        return [ExecInput(command=cmd, timeout_sec=900)]


@dataclass(frozen=True)
class ColdGateDecision:
    status: str  # 'COLD_VALIDATED' | 'QUARANTINED_SELF_CONFIRMATION'
    mean_baseline: float
    mean_candidate: float
    mean_delta: float
    paired_ci_low: float
    reason: str


def evaluate_cold_promotion_gate(
    baseline_rewards: dict[str, float],
    candidate_rewards: dict[str, float],
    n_samples_per_task: int,
    sigma_aa: float = 0.015,
) -> ColdGateDecision:
    """Enforces 1-run cold validation (`n_samples == 1`) and blocks self-confirmation."""
    if n_samples_per_task != 1:
        raise ValueError(
            f"Cold Harbor gate requires strictly 1 run per task (n_samples=1); got {n_samples_per_task}"
        )
    shared_tasks = sorted(set(baseline_rewards).intersection(candidate_rewards))
    if len(shared_tasks) < 2:
        raise ValueError("Need >= 2 paired held-out Harbor tasks to compute confidence interval")

    deltas = [candidate_rewards[t] - baseline_rewards[t] for t in shared_tasks]
    mean_b = statistics.mean(baseline_rewards[t] for t in shared_tasks)
    mean_c = statistics.mean(candidate_rewards[t] for t in shared_tasks)
    mean_d = statistics.mean(deltas)
    sd = statistics.stdev(deltas) if len(deltas) > 1 else 0.0
    se = sd / math.sqrt(len(deltas))
    ci_low = mean_d - 1.96 * se
    min_bar = 2.0 * sigma_aa

    if ci_low > 0.0 and mean_d >= min_bar:
        return ColdGateDecision(
            status="COLD_VALIDATED",
            mean_baseline=mean_b,
            mean_candidate=mean_c,
            mean_delta=mean_d,
            paired_ci_low=ci_low,
            reason=f"Real gain confirmed on cold pass@1 (+{mean_d:.4f} >= {min_bar:.4f}, 95% CI low {ci_low:+.4f})",
        )
    return ColdGateDecision(
        status="QUARANTINED_SELF_CONFIRMATION",
        mean_baseline=mean_b,
        mean_candidate=mean_c,
        mean_delta=mean_d,
        paired_ci_low=ci_low,
        reason=f"Quarantined: cold delta {mean_d:+.4f} (CI low {ci_low:+.4f}) failed 2*sigma_AA bar ({min_bar:.4f})",
    )
