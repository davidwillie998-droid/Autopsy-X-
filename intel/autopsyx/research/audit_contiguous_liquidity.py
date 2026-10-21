"""Fail-closed live-cycle liquidity audit for a raw Phase 3C archive.

Only gt.pools_multi responses count as live reserve observations. Discovery
endpoints are deliberately excluded. A pool must have one valid observation
for every expected polling cycle; duplicate timestamps or extra discovery
snapshots cannot replace a missing cycle. No interpolation is performed.

This measures observed reserve continuity, not executable liquidity at a
particular trade size. Run from intel/:
python -m autopsyx.research.audit_contiguous_liquidity RUN_DIR
"""
from __future__ import annotations

import argparse
import json
import math
from collections import defaultdict
from pathlib import Path
from urllib.parse import urlparse

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
    """Legacy timestamp-only helper; archive gate uses cycle-aware audit below."""
    if expected_cadence_ms <= 0 or expected_end_ms < expected_start_ms:
        raise ValueError("invalid expected acquisition window or cadence")
    valid_by_ts: dict[int, float] = {}
    invalid_timestamps = invalid_liquidity = out_of_window_records = 0
    for row in snapshots:
        ts = row.get("timestamp_ms")
        if not isinstance(ts, int) or isinstance(ts, bool):
            invalid_timestamps += 1
            continue
        if ts < expected_start_ms or ts > expected_end_ms:
            out_of_window_records += 1
            continue
        liq = row.get("liquidity_usd")
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
        "out_of_window_records_ignored": out_of_window_records,
        "horizons": results,
        "eligible_all_horizons": all(v["status"] == "PASS" for v in results.values()),
    }


def audit_pool_cycles(
    observations: list[dict],
    *,
    expected_cycles: list[int],
    expected_start_ms: int,
    expected_end_ms: int,
    expected_cadence_ms: int,
    failed_cycles: dict[int, str] | None = None,
) -> dict:
    """Require one valid, in-window live reserve observation in every cycle."""
    if expected_cadence_ms <= 0 or not expected_cycles or expected_end_ms < expected_start_ms:
        raise ValueError("expected cycles, valid time window, and positive cadence are required")
    expected = set(expected_cycles)
    by_cycle: dict[int, list[dict]] = defaultdict(list)
    invalid_cycle_records = 0
    out_of_window_records = 0
    for row in observations:
        cycle = row.get("cycle")
        if type(cycle) is not int or cycle not in expected:
            out_of_window_records += 1
            continue
        by_cycle[cycle].append(row)

    valid_times: list[int] = []
    invalid_liquidity = 0
    duplicate_cycles = []
    missing_cycles = []
    cycle_results = []
    failed_cycles = failed_cycles or {}
    for cycle in expected_cycles:
        rows = by_cycle.get(cycle, [])
        reason = None
        if cycle in failed_cycles:
            reason = f"poll request failed: {failed_cycles[cycle]}"
        elif not rows:
            reason = "no gt.pools_multi observation recorded for expected cycle"
        elif len(rows) != 1:
            duplicate_cycles.append(cycle)
            reason = f"expected exactly one pool snapshot in cycle; found {len(rows)}"
        else:
            row = rows[0]
            ts, liq = row.get("timestamp_ms"), row.get("liquidity_usd")
            if type(ts) is not int:
                invalid_cycle_records += 1
                reason = "invalid snapshot timestamp"
            elif ts < expected_start_ms or ts > expected_end_ms:
                invalid_cycle_records += 1
                reason = f"snapshot timestamp {ts} outside live acquisition window"
            elif not isinstance(liq, (int, float)) or isinstance(liq, bool) or not math.isfinite(liq) or liq <= 0:
                invalid_liquidity += 1
                reason = "missing/non-positive liquidity"
            else:
                valid_times.append(ts)
        if reason:
            missing_cycles.append(cycle)
        cycle_results.append({"cycle": cycle, "status": "PASS" if reason is None else "FAIL",
                              "reason": reason})

    valid_times.sort()
    max_gap = max((b - a for a, b in zip(valid_times, valid_times[1:])), default=0)
    expected_count = len(expected_cycles)
    observed_count = len(valid_times)
    results = {}
    for label, horizon_ms in HORIZONS_MS.items():
        reasons = []
        if observed_count != expected_count:
            reasons.append(f"valid live-cycle observations {observed_count} != expected cycles {expected_count}")
        if missing_cycles:
            reasons.append(f"missing/invalid expected polling cycles: {missing_cycles}")
        if max_gap > horizon_ms:
            reasons.append(f"maximum valid observation gap {max_gap}ms > {horizon_ms}ms")
        if duplicate_cycles:
            reasons.append(f"duplicate snapshots for cycles: {duplicate_cycles}")
        if invalid_cycle_records:
            reasons.append(f"{invalid_cycle_records} invalid cycle timestamp record(s)")
        if invalid_liquidity:
            reasons.append(f"{invalid_liquidity} missing/non-positive liquidity record(s)")
        results[label] = {
            "status": "PASS" if not reasons else "NON_CONTIGUOUS",
            "expected_snapshots": expected_count,
            "observed_positive_liquidity_snapshots": observed_count,
            "max_gap_ms": max_gap,
            "reasons": reasons,
        }
    return {
        "expected_start_ms": expected_start_ms,
        "expected_end_ms": expected_end_ms,
        "expected_cadence_ms": expected_cadence_ms,
        "expected_cycles": expected_cycles,
        "observed_cycles": sorted(c for c, rows in by_cycle.items() if rows),
        "cycle_results": cycle_results,
        "missing_cycles": missing_cycles,
        "duplicate_cycles": duplicate_cycles,
        "invalid_cycle_timestamp_records": invalid_cycle_records,
        "invalid_liquidity_records": invalid_liquidity,
        "out_of_window_records_ignored": out_of_window_records,
        "observed_timestamps_ms": valid_times,
        "horizons": results,
        "eligible_all_horizons": all(v["status"] == "PASS" for v in results.values()),
    }


def _pools_from_multi_url(url: str) -> list[str]:
    """Recover a failed pools/multi batch from the recorded request URL."""
    path = urlparse(url).path
    marker = "/pools/multi/"
    if marker not in path:
        return []
    tail = path.split(marker, 1)[1].split("/", 1)[0]
    return [pool for pool in tail.split(",") if pool]


def audit_archive(run_dir: str | Path) -> dict:
    """Audit every selected pool against every expected live polling cycle."""
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

    poll_start = meta.get("poll_window_started_ms")
    cycles = meta.get("poll_window_cycles", meta.get("cycles"))
    poll_end = meta.get("ended_ms")
    if (type(poll_start) is not int or type(poll_end) is not int or poll_end < poll_start
            or type(cycles) is not int or cycles < 1):
        raise ValueError("run.json lacks a valid live polling start/end and cycle count")
    cadence_ms = int(plan.get("cycle_s", 60)) * 1000
    if cadence_ms <= 0:
        raise ValueError("invalid polling cadence in run plan")
    expected_cycles = list(range(cycles))

    by_pool: dict[str, list[dict]] = defaultdict(list)
    failed_by_pool: dict[str, dict[int, str]] = defaultdict(dict)
    missing_cycle_batches: dict[int, list[str]] = defaultdict(list)

    # Crucially, only authoritative live polls are used. Discovery/backfill
    # endpoints are never eligible to fill a live polling cycle.
    for entry in raw.entries():
        if entry.endpoint != "gt.pools_multi":
            continue
        context = entry.context or {}
        cycle = context.get("cycle")
        if type(cycle) is not int or cycle not in set(expected_cycles):
            missing_cycle_batches[-1].append(f"request seq {entry.seq} has invalid/out-of-window cycle {cycle!r}")
            continue
        body = raw.body(entry.raw_id) if entry.raw_id else None
        if entry.error or body is None:
            targets = context.get("pools")
            if not isinstance(targets, list) or not targets:
                targets = _pools_from_multi_url(entry.url)
            if not targets:
                missing_cycle_batches[cycle].append(
                    f"failed request seq {entry.seq}; cannot identify its requested pool batch"
                )
            for pool_id in targets:
                failed_by_pool[pool_id][cycle] = entry.error or "response body missing"
            continue
        parsed = gt.parse_pools(entry, body)
        for rec in parsed.records:
            if type(rec).__name__ != "PoolSnapshot":
                continue
            by_pool[rec.pool].append({
                "cycle": cycle,
                "timestamp_ms": rec.seen_ts,
                "liquidity_usd": rec.liquidity_usd,
            })

    rows = []
    for pool in pools:
        pool_id, token_id = pool["pool"], pool["token"]
        audit = audit_pool_cycles(
            by_pool.get(pool_id, []),
            expected_cycles=expected_cycles,
            expected_start_ms=poll_start,
            expected_end_ms=poll_end,
            expected_cadence_ms=cadence_ms,
            failed_cycles=failed_by_pool.get(pool_id, {}),
        )
        audit.update({"pool": pool_id, "token": token_id})
        rows.append(audit)

    token_to_pools: dict[str, list[dict]] = defaultdict(list)
    for row in rows:
        token_to_pools[row["token"]].append(row)
    eligible_tokens = sorted(
        token for token, token_rows in token_to_pools.items()
        if any(p["eligible_all_horizons"] for p in token_rows)
    )
    report = {
        "schema_version": 2,
        "archive": run_dir.name,
        "acquisition_status": meta.get("status"),
        "method": "gt.pools_multi_live_cycle_exact_match_no_interpolation",
        "expected_cadence_ms": cadence_ms,
        "expected_cycle_count": cycles,
        "horizons_ms": HORIZONS_MS,
        "pool_count": len(rows),
        "eligible_pool_count": sum(p["eligible_all_horizons"] for p in rows),
        "eligible_distinct_token_count": len(eligible_tokens),
        "eligible_token_ids": eligible_tokens,
        "unattributable_failed_batches": {str(k): v for k, v in missing_cycle_batches.items()},
        "rows": rows,
        "all_pools_pass": bool(rows) and all(p["eligible_all_horizons"] for p in rows),
        "continuity_gate_pass": meta.get("status") == "COMPLETE" and bool(rows) and all(p["eligible_all_horizons"] for p in rows),
        "limitations": [
            "Only gt.pools_multi live polling observations count; discovery/backfill snapshots are excluded.",
            "Every selected pool must have exactly one valid reserve snapshot in every expected cycle.",
            "Missing, failed, duplicate, or non-positive observations are not interpolated.",
            "Positive reserve continuity is not proof of executable liquidity or acceptable price impact at a specified trade size.",
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
    return 0 if report["continuity_gate_pass"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
