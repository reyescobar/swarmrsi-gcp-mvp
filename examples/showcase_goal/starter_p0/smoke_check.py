# Copyright 2026 Google LLC
# SPDX-License-Identifier: Apache-2.0
"""Fast (<1s) local smoke test run inside the microVM during pi-mono's 4-attempt OODA loop."""
import math
from src.denoiser import recover_signal


def main() -> None:
    adj = [[1, 2], [0, 2], [0, 1, 3], [2]]
    obs = [1.0, 0.0, 1.1, 0.95]
    mask = [1, 0, 1, 1]
    pred = recover_signal(adj, obs, mask)
    assert isinstance(pred, list) and len(pred) == 4, "Output must be a list of length n"
    assert all(isinstance(x, (int, float)) and math.isfinite(x) for x in pred), "Non-finite output"
    print("SMOKE_OK", [round(x, 4) for x in pred])


if __name__ == "__main__":
    main()
