#!/usr/bin/env bash
set -euo pipefail

# Trap SIGTERM without exiting PID 1 per Agent Substrate eviction contract
trap 'echo "SIGTERM received; awaiting SuspendActor checkpoint"' TERM

# Start guest-local dockerd inside Cloud Hypervisor microVM kernel
dockerd --host=unix:///var/run/docker.sock --storage-driver=overlay2 >/var/log/dockerd.log 2>&1 &
until docker info >/dev/null 2>&1; do sleep 0.5; done

# Minimal :80 health + cold-harbor trigger server
python3 - << 'PY'
from http.server import BaseHTTPRequestHandler, HTTPServer
import json, subprocess

class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path == "/health":
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.end_headers()
            self.wfile.write(b'{"status":"ok","dockerd":"ready"}')
            return
        self.send_response(404); self.end_headers()

    def do_POST(self):
        if self.path == "/run-cold-harbor":
            length = int(self.headers.get("Content-Length", "0"))
            spec = json.loads(self.rfile.read(length) or b"{}")
            cmd = [
                "harbor", "run",
                "--dataset", spec["dataset_path"],
                "--agent-import-path", "meta_loop.swarm_harbor_agent:SwarmPiMonoHarborAgent",
                "--agent-kwarg", f"bundle_local_dir={spec['bundle_dir']}",
                "--model", spec.get("model", "gemini-3.5-flash"),
                "--n-samples", "1",
                "--n-concurrent", "2",
                "--output-dir", "/workspace/harbor-cold-report",
            ]
            subprocess.Popen(cmd, cwd="/opt/meta")
            self.send_response(202)
            self.end_headers()
            self.wfile.write(b'{"accepted":true,"n_samples":1}')
            return
        self.send_response(404); self.end_headers()

HTTPServer(("0.0.0.0", 80), Handler).serve_forever()
PY
