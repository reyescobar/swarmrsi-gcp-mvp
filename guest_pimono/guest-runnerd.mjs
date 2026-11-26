// /opt/swarm/guest-runnerd.mjs — PID 1 HTTP wrapper inside Agent Substrate microVM (:80)
import http from "node:http";
import { spawn, execFileSync } from "node:child_process";
import crypto from "node:crypto";
import fs from "node:fs/promises";
import path from "node:path";

const PORT = Number(process.env.PORT || 80);
const BROKER = process.env.BROKER_BASE_URL || "http://broker.harness.svc.cluster.local:8080";
const WS = process.env.WORKSPACE_ROOT || "/workspace";
let busy = false;
let draining = false;
let activeChild = null;

// Agent Substrate v1.0.1 Eviction Contract: SIGTERM MUST NOT exit PID 1,
// allowing SuspendActor --mode=sync to checkpoint guest state cleanly.
process.on("SIGTERM", () => {
  draining = true;
});

async function postJson(url, token, body) {
  const res = await fetch(url, {
    method: "POST",
    headers: { "content-type": "application/json", authorization: `Bearer ${token}` },
    body: JSON.stringify(body),
  });
  return { status: res.status, data: await res.json().catch(() => ({})) };
}

async function executeTrial(spec) {
  const actorName = (await fs.readFile("/run/ate/info/actor-name", "utf8").catch(() => "local-actor")).trim();
  const ephemeralCfgDir = `/tmp/pi-lease-${crypto.randomBytes(6).toString("hex")}`;
  await fs.mkdir(path.join(ephemeralCfgDir, "extensions"), { recursive: true });

  if (spec.parent_patch_b64) {
    const patchFile = path.join(ephemeralCfgDir, "parent.patch");
    await fs.writeFile(patchFile, Buffer.from(spec.parent_patch_b64, "base64"));
    execFileSync("git", ["apply", "--whitespace=nowarn", patchFile], { cwd: `${WS}/repo` });
  }
  await fs.writeFile(`${WS}/TASK_BRIEF.md`, spec.task_brief_markdown, "utf8");
  await fs.writeFile(`${ephemeralCfgDir}/trial_policy.json`, JSON.stringify({
    campaign_id: spec.campaign_id,
    root_hypothesis_id: spec.root_hypothesis_id,
    allowed_edit_globs: spec.allowed_edit_globs,
    smoke_cmd: spec.smoke_cmd,
    max_local_attempts: spec.max_local_attempts ?? 4,
    broker_url: BROKER,
    lease_token: spec.lease_token,
  }));

  await fs.copyFile("/opt/swarm/extensions/swarm-guardrail.ts", `${ephemeralCfgDir}/extensions/swarm-guardrail.ts`);
  await fs.writeFile(`${ephemeralCfgDir}/models.json`, JSON.stringify({
    providers: {
      "swarm-broker": {
        name: "Swarm Keyless Vertex Broker",
        baseUrl: `${BROKER}/v1`,
        api: "openai-completions",
        apiKey: spec.lease_token,
        models: { [spec.worker_model]: { name: spec.worker_model } },
      },
    },
  }));

  const hb = setInterval(async () => {
    const { status } = await postJson(`${BROKER}/internal/lease-heartbeat`, spec.lease_token, {
      actor_name: actorName,
      lease_id: spec.lease_id,
      draining,
    }).catch(() => ({ status: 200 }));
    if (status === 409 && activeChild) activeChild.kill("SIGKILL");
  }, 5000);

  const runnerCmd = process.env.RUNNER_HARNESS === "hermes"
    ? ["hermes", "run", "--non-interactive", "--prompt-file", `${WS}/TASK_BRIEF.md`]
    : ["pi", "--provider", "swarm-broker", "--model", spec.worker_model, "--print", `Read ${WS}/TASK_BRIEF.md and execute the assigned operator.`];

  try {
    await new Promise((resolve) => {
      activeChild = spawn(runnerCmd[0], runnerCmd.slice(1), {
        cwd: `${WS}/repo`,
        env: {
          ...process.env,
          PATH: `/opt/swarm/bundle/scripts:${process.env.PATH}`,
          PI_CODING_AGENT_DIR: ephemeralCfgDir,
          SWARM_POLICY_PATH: `${ephemeralCfgDir}/trial_policy.json`,
          OPENAI_BASE_URL: `${BROKER}/v1`,
          OPENAI_API_KEY: spec.lease_token,
          HERMES_DISABLE_SKILL_WRITE: "1",
        },
      });
      activeChild.on("close", resolve);
    });

    execFileSync("git", ["add", "-N", "."], { cwd: `${WS}/repo` });
    const diffBuf = execFileSync("git", ["diff", "--binary", "HEAD"], { cwd: `${WS}/repo`, maxBuffer: 32 * 1024 * 1024 });
    const patchSha256 = crypto.createHash("sha256").update(diffBuf).digest("hex");
    const claimRaw = await fs.readFile(`${WS}/candidate_claim.json`, "utf8").catch(() => "{}");

    await postJson(`${BROKER}/internal/trial-complete`, spec.lease_token, {
      actor_name: actorName,
      lease_id: spec.lease_id,
      patch_sha256: patchSha256,
      patch_b64: diffBuf.toString("base64"),
      candidate_claim: JSON.parse(claimRaw),
    });
  } finally {
    clearInterval(hb);
    activeChild = null;
    busy = false;
    await fs.rm(ephemeralCfgDir, { recursive: true, force: true }).catch(() => {});
  }
}

http.createServer(async (req, res) => {
  if (req.method === "GET" && req.url === "/health") {
    res.writeHead(200, { "content-type": "application/json" });
    return res.end(JSON.stringify({ status: "ok", busy, draining }));
  }
  if (req.method === "POST" && req.url === "/run-trial") {
    if (busy) { res.writeHead(409); return res.end("actor busy"); }
    busy = true;
    let raw = "";
    for await (const chunk of req) raw += chunk;
    const spec = JSON.parse(raw);
    executeTrial(spec);
    res.writeHead(202, { "content-type": "application/json" });
    return res.end(JSON.stringify({ accepted: true, lease_id: spec.lease_id }));
  }
  res.writeHead(404);
  res.end();
}).listen(PORT);
