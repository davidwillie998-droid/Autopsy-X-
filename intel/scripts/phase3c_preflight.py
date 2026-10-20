"""Fail-closed preflight for frozen Phase 3C acquisition requests.

This performs local validation only; it never contacts providers or starts a run.
"""
from __future__ import annotations

import json
import sys
from pathlib import Path

REQUIRED_STRATA = ("young", "quiet_young", "trending", "established")
MIN_STRATA_TOTAL = 20
MIN_DURATION_SECONDS = 7200


def validate(request: object) -> list[str]:
    errors: list[str] = []
    if not isinstance(request, dict):
        return ["request must be a JSON object"]
    run_id = request.get("run_id")
    if not isinstance(run_id, str) or not run_id.startswith("p3c-sol-"):
        errors.append("run_id must be a non-empty Phase 3C id beginning p3c-sol-")
    strata = request.get("strata")
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
        elif sum(values) < MIN_STRATA_TOTAL:
            errors.append(
                f"strata total {sum(values)} is below frozen protocol minimum "
                f"{MIN_STRATA_TOTAL}; do not lower the 85-token statistical gate"
            )
    duration = request.get("duration_s")
    if type(duration) is not int or duration < MIN_DURATION_SECONDS:
        errors.append(f"duration_s must be an integer >= {MIN_DURATION_SECONDS}")
    cycle = request.get("cycle_s")
    if type(cycle) is not int or cycle != 60:
        errors.append("cycle_s must remain 60 seconds under the frozen protocol")
    for key, low, high in (("rpc_max_pages", 1, 3), ("rpc_max_txs", 1, 40)):
        value = request.get(key)
        if type(value) is not int or not low <= value <= high:
            errors.append(f"{key} must be an integer in [{low}, {high}]")
    if request.get("phase3a") is not True:
        errors.append("phase3a must be true for Phase 3C enrichment")
    return errors


def main(argv: list[str] | None = None) -> int:
    args = argv if argv is not None else sys.argv[1:]
    if len(args) != 1:
        print("usage: phase3c_preflight.py REQUEST.json", file=sys.stderr)
        return 2
    path = Path(args[0])
    try:
        request = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        print(f"FAIL: cannot read valid request JSON: {exc}", file=sys.stderr)
        return 2
    errors = validate(request)
    if errors:
        for error in errors:
            print(f"FAIL: {error}", file=sys.stderr)
        return 1
    print("PASS: request meets frozen Phase 3C structural constraints.")
    print("NOTE: this does not guarantee provider completeness, polling cycles, provenance, or statistical readiness.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
