// /opt/swarm/extensions/swarm-guardrail.ts — Deterministic OODA Guardrail Hook for pi-mono
import type { ExtensionAPI } from "@mariozechner/pi-coding-agent";
import { execFileSync } from "node:child_process";
import crypto from "node:crypto";
import fs from "node:fs";
import path from "node:path";

interface TrialPolicy {
  campaign_id: string;
  root_hypothesis_id: string;
  allowed_edit_globs: string[];
  smoke_cmd: string;
  max_local_attempts: number;
  broker_url: string;
  lease_token: string;
}

export default function swarmGuardrail(pi: ExtensionAPI) {
  const policy: TrialPolicy = JSON.parse(fs.readFileSync(process.env.SWARM_POLICY_PATH!, "utf8"));
  let smokeAttempts = 0;
  let stallSummaryInjected = false;
  let preBashProtectedDigests = new Map<string, string>();

  const isAllowedPath = (relPath: string): boolean => {
    const clean = relPath.replace(/^\.?\//, "");
    if (clean === "candidate_claim.json" || clean === "../candidate_claim.json") return true;
    if (clean.startsWith(".git/") || clean.startsWith("../donors/") || clean.includes("TASK_BRIEF.md")) return false;
    return policy.allowed_edit_globs.some((prefix) => prefix === "*" || clean.startsWith(prefix.replace(/\*+$/, "")));
  };

  const snapshotProtectedFiles = (): Map<string, string> => {
    const tracked = execFileSync("git", ["ls-files"], { encoding: "utf8" }).split("\n").filter(Boolean);
    const digests = new Map<string, string>();
    for (const f of tracked) {
      if (!isAllowedPath(f) && fs.existsSync(f)) {
        digests.set(f, crypto.createHash("sha256").update(fs.readFileSync(f)).digest("hex"));
      }
    }
    return digests;
  };

  pi.on("tool_call", async (event) => {
    if (event.toolName === "write" || event.toolName === "edit") {
      const target = String(event.input.path ?? event.input.file_path ?? "");
      const rel = path.relative(process.cwd(), path.resolve(process.cwd(), target));
      if (!isAllowedPath(rel)) {
        return {
          block: true,
          reason: `Blocked by Harness policy: '${rel}' is outside allowed_edit_globs (${policy.allowed_edit_globs.join(", ")}).`,
        };
      }
    }
    if (event.toolName === "bash") {
      const cmd = String(event.input.command ?? "");
      if (smokeAttempts >= policy.max_local_attempts && cmd.includes(policy.smoke_cmd)) {
        return {
          block: true,
          reason: `Local smoke budget exhausted (${policy.max_local_attempts}/${policy.max_local_attempts}). Write /workspace/candidate_claim.json so the external Verifier can score your best branch.`,
        };
      }
      preBashProtectedDigests = snapshotProtectedFiles();
    }
    return undefined;
  });

  pi.on("tool_result", async (event) => {
    if (event.toolName !== "bash") return undefined;

    const tampered: string[] = [];
    for (const [f, oldHash] of preBashProtectedDigests.entries()) {
      const curHash = fs.existsSync(f) ? crypto.createHash("sha256").update(fs.readFileSync(f)).digest("hex") : "DELETED";
      if (curHash !== oldHash) {
        execFileSync("git", ["checkout", "--", f]);
        tampered.push(f);
      }
    }

    const cmd = String(event.input?.command ?? "");
    const outputText = String(event.result ?? "");
    const exitFailed = event.isError === true || /exit code [1-9]/i.test(outputText);

    if (cmd.includes(policy.smoke_cmd)) {
      smokeAttempts += 1;
      if (exitFailed && !stallSummaryInjected) {
        stallSummaryInjected = true;
        try {
          const res = await fetch(`${policy.broker_url}/mcp/pull-stall-summary`, {
            method: "POST",
            headers: { "content-type": "application/json", authorization: `Bearer ${policy.lease_token}` },
            body: JSON.stringify({
              campaign_id: policy.campaign_id,
              exclude_root_hypothesis_id: policy.root_hypothesis_id,
            }),
          });
          if (res.ok) {
            const peerSummary = await res.text();
            return { result: `${outputText}\n\n[HARNESS STALL ASSIST — PEER BLACKBOARD SUMMARY (READ-ONLY)]:\n${peerSummary}` };
          }
        } catch {
          // Continue within remaining local attempts
        }
      }
    }

    if (tampered.length > 0) {
      return { result: `${outputText}\n[HARNESS SECURITY REVERT]: Reverted unauthorized bash edits to: ${tampered.join(", ")}.` };
    }
    return undefined;
  });
}
