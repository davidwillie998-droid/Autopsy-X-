"""Fail-closed preflight for frozen Phase 3C acquisition requests.

This performs local validation only; it never contacts providers or starts a run.
"""
from __future__ import annotations

import json
import math
import sys
from pathlib import Path

REQUIRED_STRATA = ("young", "quiet_young", "trending", "established")
FROZEN_BASELINE_MIN_STRATA_TOTAL = 20
MIN_STATISTICAL_SAMPLE = 85
MIN_DURATION_SECONDS = 7200


def validate(request: object, *, allow_frozen_baseline: bool = False) -> list[str]:
    errors: list[str] = []
    if not isinstance(request, dict):
        return ["request must be a JSON object"]

    run_id = request.get("run_id")
    if not isinstance(run_id, str) or not run_id.startswith("p3c-sol-"):
        errors.append("run_id must be a non-empty Phase 3C id beginning p3c-sol-")
    if request.get("network") != "solana":
        errors.append("network must remain solana for the frozen Phase 3C universe")
    if type(request.get("seed")) is not int:
        errors.append("seed must be an integer")

    strata = request.get("strata")
    strata_total = None
    if not isinstance(strata, dict):
        errors.append("strata must be an object")
    else:
        unknown = sorted(set(strata) - set(REQUIRED_STRATA))
        missing = sorted(set(REQUIRED_STRATA) - set(strata))
        if unknown:
            errors.append(f"unknown strata: {', '.join(unknown)}")
        if missing:
            errors.append(f"missing strata: {', '.join(missing)}")
        values = [strata.get(k) for k in REQUIRED_STRATA]
        if any(type(v) is not int or v < 0 for v in values):
            errors.append("each stratum must be a non-negative integer")
        else:
            strata_total = sum(values)
            minimum = FROZEN_BASELINE_MIN_STRATA_TOTAL if allow_frozen_baseline else MIN_STATISTICAL_SAMPLE
            if strata_total < minimum:
                label = "frozen baseline structural minimum" if allow_frozen_baseline else "distinct-token sample minimum"
                errors.append(
                    f"strata total {strata_total} is below {label} {minimum}; "
                    "the >=85-token statistical gate must not be weakened"
                )

    duration = request.get("duration_s")
    if type(duration) is not int or duration < MIN_DURATION_SECONDS:
        errors.append(f"duration_s must be an integer >= {MIN_DURATION_SECONDS}")
    cycle = request.get("cycle_s")
    if type(cycle) is not int or cycle != 60:
        errors.append("cycle_s must remain 60 seconds under the frozen protocol")

    for key in ("new_pool_pages", "backfill_pages", "ohlcv_every"):
        value = request.get(key)
        if type(value) is not int or value < 1:
            errors.append(f"{key} must be a positive integer")
    limit = request.get("poll_ohlcv_limit")
    if type(limit) is not int or not 1 <= limit <= 1000:
        errors.append("poll_ohlcv_limit must be an integer in [1, 1000]")

    poll_budget = request.get("poll_pools_per_cycle")
    if type(poll_budget) is not int or poll_budget < 1:
        errors.append("poll_pools_per_cycle must be a positive integer")
    elif strata_total is not None and poll_budget > strata_total:
        errors.append("poll_pools_per_cycle cannot exceed the selected-pool stratum total")

    for key in ("holders_per_cycle", "lag_ms", "circuit_waits"):
        value = request.get(key)
        if type(value) is not int or value < 0:
            errors.append(f"{key} must be a non-negative integer")

    for key in ("gt_rate_per_s", "gt_min_rate_per_s", "rpc_rate_per_s"):
        value = request.get(key)
        if isinstance(value, bool) or not isinstance(value, (int, float)) or not math.isfinite(value) or value <= 0:
            errors.append(f"{key} must be a finite positive number")
    gt_rate, gt_min = request.get("gt_rate_per_s"), request.get("gt_min_rate_per_s")
    if (isinstance(gt_rate, (int, float)) and not isinstance(gt_rate, bool)
            and isinstance(gt_min, (int, float)) and not isinstance(gt_min, bool)
            and gt_min > gt_rate):
        errors.append("gt_min_rate_per_s cannot exceed gt_rate_per_s")

    for key, low, high in (("rpc_max_pages", 1, 3), ("rpc_max_txs", 1, 300)):
        value = request.get(key)
        if type(value) is not int or not low <= value <= high:
            errors.append(f"{key} must be an integer in [{low}, {high}]")
    if request.get("phase3a") is not True:
        errors.append("phase3a must be true for Phase 3C enrichment")
    return errors


def main(argv: list[str] | None = None) -> int:
    args = list(argv if argv is not None else sys.argv[1:])
    allow_frozen_baseline = bool(args and args[0] == "--frozen-baseline")
    if allow_frozen_baseline:
        args = args[1:]
    if len(args) != 1:
        print("usage: phase3c_preflight.py [--frozen-baseline] REQUEST.json", file=sys.stderr)
        return 2
    path = Path(args[0])
    try:
        request = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        print(f"FAIL: cannot read valid request JSON: {exc}", file=sys.stderr)
        return 2
    errors = validate(request, allow_frozen_baseline=allow_frozen_baseline)
    if errors:
        for error in errors:
            print(f"FAIL: {error}", file=sys.stderr)
        return 1
    print("PASS: request meets frozen Phase 3C structural constraints.")
    print("NOTE: this does not guarantee provider completeness, polling cycles, provenance, or statistical readiness.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
