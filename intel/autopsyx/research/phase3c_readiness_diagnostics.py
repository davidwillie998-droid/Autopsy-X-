"""Read-only Phase 3C acquisition diagnostics.

This module does not change normalization, acquisition, readiness thresholds,
or the frozen Phase 2/3A/3B contracts. It measures what the raw archive can
actually support and reports missingness explicitly. UNKNOWN is not treated
as zero or as a pass.
"""
from __future__ import annotations

import argparse
import json
import math
from collections import Counter, defaultdict
from pathlib import Path

from ..data.providers import geckoterminal as gt
from ..data.raw import RawStore
from . import phase3a_coverage


MINUTE_MS = 60_000


def summarize_timestamps(timestamps: list[int], *, created_ts: int | None = None,
                         interval_ms: int = MINUTE_MS) -> dict:
    """Describe unique bar timestamps without filling gaps or assuming liquidity."""
    if interval_ms <= 0:
        raise ValueError("interval_ms must be positive")
    counts = Counter(int(ts) for ts in timestamps)
    unique = sorted(counts)
    duplicates = sum(n - 1 for n in counts.values())
    if not unique:
        return {
            "observed_rows": len(timestamps), "unique_bars": 0, "duplicate_rows": duplicates,
            "first_bar_ms": None, "last_bar_ms": None, "observed_span_intervals": 0,
            "missing_intervals_inside_observed_span": None, "coverage_inside_observed_span": None,
            "longest_contiguous_run_bars": 0, "longest_internal_gap_intervals": 0, "misaligned_timestamps": 0,
            "created_to_last_expected_intervals": None, "missing_intervals_since_creation": None,
        }

    expected_span = ((unique[-1] - unique[0]) // interval_ms) + 1
    misaligned_timestamps = sum(ts % interval_ms != 0 for ts in unique)
    missing_inside = max(0, expected_span - len(unique))
    longest_run = 1
    run = 1
    longest_gap = 0
    for left, right in zip(unique, unique[1:]):
        delta = right - left
        steps = max(1, round(delta / interval_ms))
        if delta == interval_ms:
            run += 1
            longest_run = max(longest_run, run)
        else:
            run = 1
            longest_gap = max(longest_gap, steps - 1)

    created_expected = None
    missing_since_creation = None
    if created_ts is not None and created_ts <= unique[-1]:
        # Expected minute slots from the first minute at/after pool creation to
        # the last observed bar. Creation time is a bound, not proof of trading.
        first_expected = ((created_ts + interval_ms - 1) // interval_ms) * interval_ms
        created_expected = max(0, ((unique[-1] - first_expected) // interval_ms) + 1)
        observed_after_creation = sum(first_expected <= ts <= unique[-1] for ts in unique)
        missing_since_creation = max(0, created_expected - observed_after_creation)

    return {
        "observed_rows": len(timestamps),
        "unique_bars": len(unique),
        "duplicate_rows": duplicates,
        "first_bar_ms": unique[0],
        "last_bar_ms": unique[-1],
        "observed_span_intervals": expected_span,
        "missing_intervals_inside_observed_span": missing_inside,
        "coverage_inside_observed_span": len(unique) / expected_span if expected_span else None,
        "longest_contiguous_run_bars": longest_run,
        "longest_internal_gap_intervals": longest_gap,
        "misaligned_timestamps": misaligned_timestamps,
        "created_to_last_expected_intervals": created_expected,
        "missing_intervals_since_creation": missing_since_creation,
    }


def _entry_error(entry) -> bool:
    return bool(entry.error or entry.raw_id is None or (entry.status is not None and entry.status != 200))


def audit_archive(run_dir: Path) -> dict:
    """Read raw requests and reparse OHLCV; return a deterministic diagnostic report."""
    raw = RawStore(str(run_dir))
    meta = raw.read_json("run.json") or {}
    selection_source, selected = phase3a_coverage.universe(raw)
    selected_by_pool = {p["pool"]: p for p in selected if p.get("pool")}
    entries = raw.entries()
    plan = meta.get("plan") or {}
    lag_ms = int(plan.get("lag_ms", 60_000))
    interval_ms = MINUTE_MS
    backfill_page_size_bars = 1000  # explicit limit passed to gt.path_ohlcv in acquire.backfill

    request_counts = Counter()
    error_counts = Counter()
    issue_counts = Counter()
    bars_by_pool: dict[str, list[int]] = defaultdict(list)
    bars_by_pool_token: dict[str, str] = {}
    response_counts = Counter()
    pool_errors: dict[str, Counter] = defaultdict(Counter)
    pages_by_pool: dict[str, set[int]] = defaultdict(set)
    poll_cycles_by_pool: dict[str, set[int]] = defaultdict(set)
    raw_bars_by_pool = Counter()

    for entry in entries:
        endpoint = entry.endpoint
        if endpoint != "gt.ohlcv":
            continue
        ctx = entry.context or {}
        pool = ctx.get("pool")
        if pool:
            request_counts["total_ohlcv"] += 1
            if "cycle" in ctx:
                request_counts["poll_ohlcv"] += 1
                try:
                    poll_cycles_by_pool[pool].add(int(ctx["cycle"]))
                except (TypeError, ValueError):
                    pass
            if "page" in ctx:
                request_counts["backfill_ohlcv"] += 1
                try:
                    pages_by_pool[pool].add(int(ctx["page"]))
                except (TypeError, ValueError):
                    pass
        if _entry_error(entry):
            request_counts["failed_ohlcv"] += 1
            error_counts[str(entry.error or f"HTTP {entry.status}")] += 1
            if pool:
                pool_errors[pool]["failed_requests"] += 1
            continue
        response_counts["successful_ohlcv"] += 1
        parsed = gt.parse_ohlcv(entry, raw.body(entry.raw_id), lag_ms)
        for issue in parsed.issues:
            issue_counts[issue.code] += 1
            if pool:
                pool_errors[pool][issue.code] += 1
        for record in parsed.records:
            if type(record).__name__ != "ProviderBar":
                continue
            bars_by_pool[record.pool].append(int(record.ts))
            bars_by_pool_token[record.pool] = record.token
            raw_bars_by_pool[record.pool] += 1

    pool_reports = {}
    for pool in sorted(set(selected_by_pool) | set(bars_by_pool) | set(pool_errors)):
        selected_item = selected_by_pool.get(pool, {})
        created_ts = selected_item.get("created_ts")
        if not isinstance(created_ts, int):
            created_ts = None
        timestamps = bars_by_pool.get(pool, [])
        stats = summarize_timestamps(timestamps, created_ts=created_ts, interval_ms=interval_ms)
        cycles = sorted(poll_cycles_by_pool.get(pool, set()))
        pages = sorted(pages_by_pool.get(pool, set()))
        pool_reports[pool] = {
            "token": selected_item.get("token") or bars_by_pool_token.get(pool),
            "selected": pool in selected_by_pool,
            "ohlcv_requests": 1 * (sum(1 for e in entries if e.endpoint == "gt.ohlcv" and (e.context or {}).get("pool") == pool)),
            "backfill_page_indices": pages,
            "poll_cycle_indices": cycles,
            "first_poll_cycle": cycles[0] if cycles else None,
            "last_poll_cycle": cycles[-1] if cycles else None,
            "request_errors": dict(sorted(pool_errors.get(pool, {}).items())),
            **stats,
        }

    cycles_raw = meta.get("poll_window_cycles")
    cycle_source = "poll_window_cycles"
    if not isinstance(cycles_raw, (int, float)):
        # Older archives used the same counter under `cycles` but did not save
        # the actual elapsed polling-window duration.
        cycles_raw = meta.get("cycles")
        cycle_source = "legacy_cycles_field"
    cycles = int(cycles_raw) if isinstance(cycles_raw, (int, float)) else None
    every = max(1, int(plan.get("ohlcv_every") or 1))
    expected_poll_calls = math.ceil(cycles / every) * len(selected) if selected and cycles is not None else None
    actual_poll_calls = int(request_counts["poll_ohlcv"])
    duration_s = plan.get("duration_s")
    elapsed_s = meta.get("poll_window_elapsed_s")
    return {
        "schema_version": 1,
        "diagnostic_only": True,
        "archive": run_dir.name,
        "run_id": meta.get("run_id"),
        "code_version": meta.get("code_version"),
        "acquisition_status": meta.get("status", "UNKNOWN"),
        "selection_source": selection_source,
        "selected_pool_count": len(selected),
        "run_window": {
            "configured_duration_s": duration_s,
            "observed_elapsed_s": elapsed_s,
            "completed_cycles": cycles,
            "cycle_telemetry_available": cycles is not None,
            "cycle_count_source": cycle_source if cycles is not None else None,
            "window_duration_reached": (
                elapsed_s >= duration_s if isinstance(elapsed_s, (int, float))
                and isinstance(duration_s, (int, float)) else None
            ),
        },
        "configured_history_cap": {
            "backfill_pages_per_pool": plan.get("backfill_pages"),
            "provider_bars_per_page": backfill_page_size_bars,
            "maximum_requested_minute_bars_per_pool": (
                int(plan["backfill_pages"]) * backfill_page_size_bars
                if isinstance(plan.get("backfill_pages"), (int, float)) else None
            ),
            "maximum_requested_history_hours_per_pool": (
                int(plan["backfill_pages"]) * backfill_page_size_bars / 60
                if isinstance(plan.get("backfill_pages"), (int, float)) else None
            ),
            "interpretation": "Configured upper bound only; actual bars can be lower because pools are younger, provider pages are short, requests fail, or validation rejects records.",
        },
        "request_accounting": {
            "ohlcv_requests_total": int(request_counts["total_ohlcv"]),
            "ohlcv_backfill_requests": int(request_counts["backfill_ohlcv"]),
            "ohlcv_poll_requests": actual_poll_calls,
            "ohlcv_failed_requests": int(request_counts["failed_ohlcv"]),
            "expected_poll_requests_from_cycle_count": expected_poll_calls,
            "poll_request_count_matches_cycle_count": (
                actual_poll_calls == expected_poll_calls if expected_poll_calls is not None else None
            ),
            "successful_ohlcv_responses": int(response_counts["successful_ohlcv"]),
            "provider_error_details": dict(sorted(error_counts.items())),
            "parsed_bar_rows": sum(raw_bars_by_pool.values()),
            "parser_issue_counts": dict(sorted(issue_counts.items())),
        },
        "pools": pool_reports,
        "limitations": [
            "This report measures observed minute-bar continuity; it does not prove executable liquidity.",
            "The created-to-last interval count is a coverage diagnostic, not a claim that every minute after pool creation should trade.",
            "No readiness thresholds are inferred or changed by this tool.",
            "Repeated bars across polling responses are reported as duplicate observations, not silently removed from the raw archive.",
            "Historical OHLCV backfill uses a provider page size of 1000 minute bars; configured page count therefore caps the maximum requested history and may be insufficient for multi-day requirements.",
        ],
    }


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("run_dir", type=Path, help="Path to one archived Phase 3C run")
    parser.add_argument("--out", type=Path, help="Optional JSON output path")
    args = parser.parse_args()
    report = audit_archive(args.run_dir)
    rendered = json.dumps(report, sort_keys=True, indent=2)
    if args.out:
        args.out.parent.mkdir(parents=True, exist_ok=True)
        args.out.write_text(rendered + "\n", encoding="utf-8")
    print(rendered)


if __name__ == "__main__":
    main()
