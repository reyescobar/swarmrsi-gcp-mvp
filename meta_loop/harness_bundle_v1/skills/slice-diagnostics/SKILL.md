---
name: slice-diagnostics
description: Inspect per-slice error residuals before proposing multi-mechanism edits.
---

# Slice Residual Diagnostics Playbook

1. Run `slice_profiler.py` on local smoke fixtures before editing `src/denoiser.py`.
2. Separate high-dropout bias (`zeros pulling neighbor averages down`) from heavy-tail outlier spikes (`extreme neighbors corrupting smooth nodes`).
3. Verify every new helper function is wired directly into the entrypoint call graph before writing `/workspace/candidate_claim.json`.
