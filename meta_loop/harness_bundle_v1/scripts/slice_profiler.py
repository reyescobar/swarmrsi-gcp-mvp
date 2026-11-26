#!/usr/bin/env python3
"""Standalone CLI helper inside /opt/swarm/bundle/scripts (evolved by Harness2)."""
import json
import sys


def summarize_residuals(values: list[float]) -> dict[str, float]:
    if not values:
        return {"count": 0, "mean_abs": 0.0, "max_abs": 0.0}
    abs_vals = [abs(v) for v in values]
    return {
        "count": len(values),
        "mean_abs": round(sum(abs_vals) / len(abs_vals), 5),
        "max_abs": round(max(abs_vals), 5),
    }


if __name__ == "__main__":
    nums = [float(x) for x in sys.argv[1:]]
    print(json.dumps(summarize_residuals(nums)))
