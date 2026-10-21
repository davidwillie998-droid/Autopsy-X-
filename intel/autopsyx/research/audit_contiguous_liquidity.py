"""Fail-closed continuity audit for pool-liquidity snapshots in a raw Phase 3C archive.

This audits observed positive pool reserves and timestamp continuity. It does not
claim an economic minimum-liquidity threshold (none is defined by the frozen
contract) and does not interpolate missing observations.
Run from intel/: python -m autopsyx.research.audit_contiguous_liquidity RUN_DIR
"""
from __future__ import annotations

import argparse
import json
import math
from collections import defaultdict
from pathlib import Path

from ..data.providers import geckoterminal as gt
from ..data.raw import RawStore

HORIZONS_MS = {"5m": 5 * 60_000, "15m": 15 * 60_000, "60m": 60 * 60_000}


def audit_pool_snapshots(
    snapshots: list[dict],
    *,
    expected_start_ms: int,
    expected_end_ms: int,
    expected_cadence_ms: int,
) -> dict:
    """Audit one pool. Snapshot dicts require timestamp_ms and liquidity_usd.

    N_expected is based on the declared acquisition window and expected per-pool
    polling cadence. Any absent/invalid reserve snapshot, count shortfall, or
    gap larger than the horizon fails that horizon. Duplicate timestamps count
    once; no interpolation/forward-fill is performed.
    """
    if expected_cadence_ms <= 0 or expected_end_ms < expected_start_ms:
        raise ValueError("invalid expected acquisition window or cadence")
    valid_by_ts: dict[int, float] = {}
    invalid_timestamps = 0
    invalid_liquidity = 0
    for row in snapshots:
        ts = row.get("timestamp_ms")
        liq = row.get("liquidity_usd")
        if not isinstance(ts, int) or isinstance(ts, bool):
            invalid_timestamps += 1
            continue
        if not isinstance(liq, (int, float)) or isinstance(liq, bool) or not math.isfinite(liq) or liq <= 0:
            invalid_liquidity += 1
            continue
        valid_by_ts[ts] = float(liq)
    times = sorted(valid_by_ts)
    expected_count = (expected_end_ms - expected_start_ms) // expected_cadence_ms + 1
    max_gap = max((b - a for a, b in zip(times, times[1:])), default=0)
    results = {}
    for label, horizon_ms in HORIZONS_MS.items():
        reasons = []
        if len(times) < expected_count:
            reasons.append(f"observed snapshots {len(times)} < expected {expected_count}")
        if max_gap > horizon_ms:
            reasons.append(f"maximum timestamp gap {max_gap}ms > {horizon_ms}ms")
        if invalid_timestamps:
            reasons.append(f"{invalid_timestamps} invalid timestamp record(s)")
        if invalid_liquidity:
            reasons.append(f"{invalid_liquidity} missing/non-positive liquidity record(s)")
        results[label] = {
            "status": "PASS" if not reasons else "NON_CONTIGUOUS",
            "expected_snapshots": expected_count,
            "observed_positive_liquidity_snapshots": len(times),
            "max_gap_ms": max_gap,
            "reasons": reasons,
        }
    return {
        "expected_start_ms": expected_start_ms,
        "expected_end_ms": expected_end_ms,
        "expected_cadence_ms": expected_cadence_ms,
        "observed_timestamps_ms": times,
        "invalid_timestamp_records": invalid_timestamps,
        "invalid_liquidity_records": invalid_liquidity,
        "horizons": results,
        "eligible_all_horizons": all(v["status"] == "PASS" for v in results.values()),
    }


def audit_archive(run_dir: str | Path) -> dict:
    """Build a machine-readable per-pool audit directly from raw archive entries."""
    run_dir = Path(run_dir)
    raw = RawStore(run_dir)
    meta = raw.read_json("run.json") or {}
    plan = meta.get("plan") or {}
    universe_doc = raw.read_json("universe.json") or {}
    pools = universe_doc.get("pools") or []
    if not pools:
        selection = raw.read_json("selection.json") or {}
        pools = [{"pool": x.get("pool"), "token": x.get("token")} for x in selection.get("picked", [])]
    pools = [p for p in pools if p.get("pool") and p.get("token")]
    if not pools:
        raise ValueError("archive has no frozen pool universe; refusing to infer eligibility")

    started = meta.get("started_ms")
    ended = meta.get("ended_ms")
    if not isinstance(started, int) or not isinstance(ended, int) or ended < started:
        raise ValueError("run.json lacks a valid started_ms/ended_ms acquisition window")
    cycle_ms = int(plan.get("cycle_s", 60)) * 1000
    rotating = plan.get("poll_pools_per_cycle")
    cadence_ms = cycle_ms * (math.ceil(len(pools) / int(rotating)) if rotating else 1)
    if cadence_ms <= 0:
        raise ValueError("invalid per-pool polling cadence in run plan")

    by_pool: dict[str, list[dict]] = defaultdict(list)
    request_errors: dict[str, int] = defaultdict(int)
    parsed_requests = 0
    for entry in raw.entries():
        if entry.endpoint not in ("gt.new_pools", "gt.trending", "gt.top_pools", "gt.pools_multi"):
            continue
        body = raw.body(entry.raw_id) if entry.raw_id else None
        if entry.error or body is None:
            context = entry.context or {}
            target = context.get("pool")
            if target:
                request_errors[target] += 1
            continue
        parsed = gt.parse_pools(entry, body)
        parsed_requests += 1
        for rec in parsed.records:
            if type(rec).__name__ != "PoolSnapshot":
                continue
            by_pool[rec.pool].append({"timestamp_ms": rec.seen_ts, "liquidity_usd": rec.liquidity_usd})

    rows = []
    for pool in pools:
        pool_id, token_id = pool["pool"], pool["token"]
        audit = audit_pool_snapshots(
            by_pool.get(pool_id, []),
            expected_start_ms=started,
            expected_end_ms=ended,
            expected_cadence_ms=cadence_ms,
        )
        audit.update({"pool": pool_id, "token": token_id, "request_errors": request_errors.get(pool_id, 0)})
        if request_errors.get(pool_id, 0):
            for horizon in audit["horizons"].values():
                horizon["status"] = "NON_CONTIGUOUS"
                horizon["reasons"].append(f"{request_errors[pool_id]} recorded request error(s) for pool")
            audit["eligible_all_horizons"] = False
        rows.append(audit)

    token_to_pools: dict[str, list[dict]] = defaultdict(list)
    for row in rows:
        token_to_pools[row["token"]].append(row)
    eligible_tokens = sorted(
        token for token, token_rows in token_to_pools.items()
        if any(p["eligible_all_horizons"] for p in token_rows)
    )
    report = {
        "schema_version": 1,
        "archive": run_dir.name,
        "acquisition_status": meta.get("status"),
        "method": "positive_pool_reserve_snapshots_no_interpolation",
        "expected_cadence_ms": cadence_ms,
        "horizons_ms": HORIZONS_MS,
        "pool_count": len(rows),
        "eligible_pool_count": sum(p["eligible_all_horizons"] for p in rows),
        "eligible_distinct_token_count": len(eligible_tokens),
        "eligible_token_ids": eligible_tokens,
        "rows": rows,
        "all_pools_pass": bool(rows) and all(p["eligible_all_horizons"] for p in rows),
        "limitations": [
            "This is observed reserve-snapshot continuity, not proof of an economic minimum-liquidity threshold.",
            "Missing, failed, or non-positive reserve observations are not interpolated.",
            "Expected snapshot count uses the run window and plan-derived per-pool cadence.",
            "The separate 85-distinct-token gate must be applied per hypothesis after its own eligibility filters.",
        ],
    }
    return report


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("run_dir", help="path to one immutable Phase 3C raw archive")
    parser.add_argument("--out", help="write JSON report to this path; default prints to stdout")
    args = parser.parse_args(argv)
    try:
        report = audit_archive(args.run_dir)
    except (OSError, ValueError, KeyError, TypeError) as exc:
        print(json.dumps({"status": "FAIL", "error": str(exc)}, indent=2))
        return 2
    rendered = json.dumps(report, indent=2, sort_keys=True)
    if args.out:
        Path(args.out).write_text(rendered + "\n", encoding="utf-8")
    else:
        print(rendered)
    return 0 if report["all_pools_pass"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
