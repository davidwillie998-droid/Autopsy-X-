"""Preflight validation for frozen Phase 3C acquisition requests.

This check is deliberately network-free. It prevents an acquisition from
starting when its declared stratified universe contradicts the frozen
protocol. It does not change the 85-token evidence threshold or guarantee
that live discovery will find the requested number of distinct tokens.
"""
from __future__ import annotations

import json
import re
import sys
from pathlib import Path

REQUIRED_STRATA = ("young", "quiet_young", "trending", "established")
MIN_REQUESTED_STRATA = 20
RUN_ID_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]{0,79}$")


def validate_request(data: object) -> list[str]:
    errors: list[str] = []
    if not isinstance(data, dict):
        return ["request must be a JSON object"]

    run_id = data.get("run_id")
    if not isinstance(run_id, str) or not RUN_ID_RE.fullmatch(run_id) or run_id in {".", ".."}:
        errors.append("run_id must be 1-80 safe filename characters")

    strata = data.get("strata")
    if not isinstance(strata, dict):
        errors.append("strata must be an object with young, quiet_young, trending, established")
    else:
        missing = [key for key in REQUIRED_STRATA if key not in strata]
        extra = [key for key in strata if key not in REQUIRED_STRATA]
        if missing:
            errors.append("strata missing required keys: " + ", ".join(missing))
        if extra:
            errors.append("strata has unknown keys: " + ", ".join(map(str, extra)))
        values = [strata.get(key) for key in REQUIRED_STRATA]
        if any(type(value) is not int or value < 0 for value in values):
            errors.append("every strata target must be a non-negative integer")
        elif not missing and not extra and sum(values) < MIN_REQUESTED_STRATA:
            errors.append(
                f"strata total is {sum(values)}; frozen Phase 3C protocol requires "
                f"at least {MIN_REQUESTED_STRATA} requested tokens"
            )

    for key in ("duration_s", "cycle_s", "new_pool_pages", "backfill_pages",
                "rpc_page_limit", "rpc_max_pages", "rpc_max_txs"):
        value = data.get(key)
        if type(value) is not int or value <= 0:
            errors.append(f"{key} must be a positive integer")

    if data.get("network") != "solana":
        errors.append("network must remain solana for this frozen Phase 3C study")
    if data.get("phase3a") is not True:
        errors.append("phase3a must be true to collect the frozen Phase 3C enrichment fields")
    return errors


def main(argv: list[str] | None = None) -> int:
    args = argv if argv is not None else sys.argv[1:]
    if len(args) != 1:
        print("usage: python scripts/validate_phase3c_request.py REQUEST.json", file=sys.stderr)
        return 2
    path = Path(args[0])
    try:
        with path.open("r", encoding="utf-8") as handle:
            data = json.load(handle)
    except (OSError, json.JSONDecodeError) as exc:
        print(f"REQUEST INVALID: cannot read valid JSON from {path}: {exc}", file=sys.stderr)
        return 2
    errors = validate_request(data)
    if errors:
        print("PHASE 3C PREFLIGHT: BLOCKED", file=sys.stderr)
        for error in errors:
            print(f"- {error}", file=sys.stderr)
        return 2
    print("PHASE 3C PREFLIGHT: PASS (request only; live yield and readiness remain unproven)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
