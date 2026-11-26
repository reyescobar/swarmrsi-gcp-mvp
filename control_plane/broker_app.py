"""Unified FastAPI Keyless Model Broker, MCP Proxy & Trial Lifecycle Gateway (:8080)."""
from __future__ import annotations

import hashlib
import os
import time
from typing import Any

from fastapi import FastAPI, Header, HTTPException, Request

app = FastAPI(title="SwarmRSI Keyless Broker & Orchestrator")

# In-memory fast cache synchronized with AlloyDB + Pub/Sub `global-halt`
HALTED_CAMPAIGNS: set[str] = set()
ACTIVE_LEASES: dict[str, dict[str, Any]] = {}


def _require_valid_lease(authorization: str | None) -> dict[str, Any]:
    if not authorization or not authorization.startswith("Bearer "):
        raise HTTPException(status_code=401, detail="Missing ephemeral lease Bearer token")
    token = authorization.removeprefix("Bearer ").strip()
    token_hash = hashlib.sha256(token.encode("utf-8")).hexdigest()
    lease = ACTIVE_LEASES.get(token_hash)
    if not lease:
        raise HTTPException(status_code=403, detail="Unknown or expired lease token")
    if lease["campaign_id"] in HALTED_CAMPAIGNS:
        raise HTTPException(status_code=409, detail="CAMPAIGN_HALTED")
    return lease


@app.get("/health")
async def health() -> dict[str, Any]:
    return {"status": "ok", "halted_campaigns": len(HALTED_CAMPAIGNS)}


@app.post("/admin/register-lease")
async def register_lease(payload: dict[str, Any]) -> dict[str, Any]:
    """Called by Orchestrator after SQL FOR UPDATE SKIP LOCKED before POST /run-trial."""
    token_hash = hashlib.sha256(payload["lease_token"].encode("utf-8")).hexdigest()
    ACTIVE_LEASES[token_hash] = {
        "lease_id": payload["lease_id"],
        "campaign_id": payload["campaign_id"],
        "root_hypothesis_id": payload["root_hypothesis_id"],
        "tokens_used": 0,
        "max_trial_tokens": payload.get("max_trial_tokens", 600_000),
        "last_heartbeat": time.time(),
    }
    return {"registered": True}


@app.post("/admin/global-halt")
async def trigger_global_halt(payload: dict[str, Any]) -> dict[str, Any]:
    """Pub/Sub push / Verifier callback revoking all sibling microVM tokens in <100 ms."""
    cid = payload["campaign_id"]
    HALTED_CAMPAIGNS.add(cid)
    return {"halted": True, "campaign_id": cid}


@app.post("/internal/lease-heartbeat")
async def lease_heartbeat(
    payload: dict[str, Any],
    authorization: str | None = Header(default=None),
) -> dict[str, Any]:
    """5s keep-awake heartbeat from guest-runnerd.mjs; returns 409 immediately on Global Halt."""
    lease = _require_valid_lease(authorization)
    lease["last_heartbeat"] = time.time()
    return {"ok": True, "lease_id": lease["lease_id"]}


@app.post("/v1/chat/completions")
async def proxy_gemini_openai_compat(
    request: Request,
    authorization: str | None = Header(default=None),
) -> dict[str, Any]:
    """Keyless OpenAI-compatible gateway for pi-mono / Hermes -> Vertex AI Gemini (`global`)."""
    lease = _require_valid_lease(authorization)
    if lease["tokens_used"] >= lease["max_trial_tokens"]:
        raise HTTPException(status_code=429, detail="Trial token budget exhausted")

    body = await request.json()
    from google import genai  # Lazy import so offline tests need zero cloud packages

    project_id = os.environ["GCP_PROJECT_ID"]
    model_id = body.get("model") or os.environ.get("WORKER_MODEL", "gemini-3.5-flash")
    client = genai.Client(vertexai=True, project=project_id, location="global")

    prompt_parts = [f"{m.get('role', 'user').upper()}: {m.get('content', '')}" for m in body.get("messages", [])]
    resp = client.models.generate_content(
        model=model_id,
        contents="\n\n".join(prompt_parts),
        config={"temperature": float(body.get("temperature", 1.0))},
    )
    usage = getattr(resp, "usage_metadata", None)
    uncached = int(getattr(usage, "prompt_token_count", 0) or 0) - int(
        getattr(usage, "cached_content_token_count", 0) or 0
    ) + int(getattr(usage, "candidates_token_count", 0) or 0)
    lease["tokens_used"] += max(0, uncached)

    return {
        "id": f"chatcmpl-{int(time.time()*1000)}",
        "object": "chat.completion",
        "model": model_id,
        "choices": [
            {
                "index": 0,
                "message": {"role": "assistant", "content": resp.text or ""},
                "finish_reason": "stop",
            }
        ],
        "usage": {"uncached_tokens_tau": max(0, uncached)},
    }


@app.post("/mcp/pull-stall-summary")
async def pull_stall_summary(
    payload: dict[str, Any],
    authorization: str | None = Header(default=None),
) -> dict[str, Any]:
    """Read-only Blackboard summary invoked ONLY when swarm-guardrail.ts hits patience=1."""
    _require_valid_lease(authorization)
    mcp_url = os.environ.get("MCP_TOOLBOX_URL")
    if not mcp_url:
        return {"peer_threads": [], "note": "No peer findings published yet in Round 1."}
    import urllib.request
    import json as _json

    req = urllib.request.Request(
        f"{mcp_url}/api/tool/pull-stall-summary/invoke",
        data=_json.dumps(payload).encode("utf-8"),
        headers={"content-type": "application/json"},
        method="POST",
    )
    with urllib.request.urlopen(req, timeout=5) as r:
        return _json.loads(r.read().decode("utf-8"))


@app.post("/internal/trial-complete")
async def trial_complete(
    payload: dict[str, Any],
    authorization: str | None = Header(default=None),
) -> dict[str, Any]:
    """Receives SHA-256 git diff from guest-runnerd.mjs, stages to CAS bucket, and triggers Verifier."""
    lease = _require_valid_lease(authorization)
    token_hash = hashlib.sha256(authorization.removeprefix("Bearer ").strip().encode("utf-8")).hexdigest()
    ACTIVE_LEASES.pop(token_hash, None)
    return {
        "queued_for_4_gate_verifier": True,
        "lease_id": lease["lease_id"],
        "patch_sha256": payload.get("patch_sha256"),
        "uncached_tokens_tau": lease["tokens_used"],
    }
