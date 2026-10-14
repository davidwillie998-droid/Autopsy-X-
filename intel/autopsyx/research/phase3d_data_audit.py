"""Audit whether archived price/liquidity data can support Phase 3D labels.

This module reports data readiness only. It does not infer labels, train a
model, or combine overlapping archives into one independent sample.
"""
from __future__ import annotations

import json
from typing import Iterable

from ..core.models import PoolSnapshot, ProviderBar
from ..data.normalize import normalize
from . import phase3c_data
from .phase3d_targets import price_bars_from_point_in_time_records


CANDIDATE_HORIZONS_MS = (5 * 60_000, 15 * 60_000, 60 * 60_000)


def _max_contiguous_liquid_bars(bars, interval_ms: int) -> int:
    best = current = 0
    previous_ts = None
    for bar in bars:
        contiguous = (
            bar.liquidity_usd is not None
            and (previous_ts is None or bar.ts_ms - previous_ts == interval_ms)
        )
        if contiguous:
            current += 1
        else:
            current = 1 if bar.liquidity_usd is not None else 0
        best = max(best, current)
        previous_ts = bar.ts_ms
    return best


def _liquidity_join_diagnostics(
    provider_bars: Iterable[object],
    liquidity_snapshots: Iterable[object],
    *,
    chain: str,
    token: str,
    pool: str,
    max_liquidity_age_ms: int,
) -> dict:
    """Explain why each bar did or did not have an admissible snapshot.

    Counts are per bar, not per rejected snapshot. Identity uses the same
    exact chain/token/pool match as the production join. No timestamp or
    address normalization is silently applied.
    """
    bars = [
        b for b in provider_bars
        if str(getattr(b, "chain", "")) == chain
        and str(getattr(b, "token", "")) == token
        and str(getattr(b, "pool", "")) == pool
    ]
    # Mirror the production join: one latest-seen provider revision per
    # bar-open timestamp, so diagnostics count bars rather than revisions.
    latest_by_ts: dict[int, object] = {}
    for bar in bars:
        ts = int(getattr(bar, "ts"))
        if ts not in latest_by_ts or int(getattr(bar, "seen_ts")) > int(getattr(latest_by_ts[ts], "seen_ts")):
            latest_by_ts[ts] = bar
    bars = [latest_by_ts[ts] for ts in sorted(latest_by_ts)]
    snapshots = [
        s for s in liquidity_snapshots
        if str(getattr(s, "chain", "")) == chain
        and str(getattr(s, "token", "")) == token
        and str(getattr(s, "pool", "")) == pool
    ]
    reasons = {
        "no_matching_snapshot": 0,
        "event_after_bar_open": 0,
        "not_ingested_by_bar_open": 0,
        "stale_snapshot": 0,
        "missing_liquidity_value": 0,
        "mixed_or_invalid_candidates": 0,
    }
    covered = 0
    for bar in bars:
        bar_ts = int(getattr(bar, "ts"))
        if not snapshots:
            reasons["no_matching_snapshot"] += 1
            continue
        eligible = [
            s for s in snapshots
            if getattr(s, "liquidity_usd", None) is not None
            and int(getattr(s, "ts")) <= bar_ts
            and int(getattr(s, "seen_ts")) <= bar_ts
            and bar_ts - int(getattr(s, "ts")) <= max_liquidity_age_ms
        ]
        if eligible:
            covered += 1
            continue
        if all(getattr(s, "liquidity_usd", None) is None for s in snapshots):
            reasons["missing_liquidity_value"] += 1
        elif all(int(getattr(s, "ts")) > bar_ts for s in snapshots):
            reasons["event_after_bar_open"] += 1
        elif all(int(getattr(s, "seen_ts")) > bar_ts for s in snapshots):
            reasons["not_ingested_by_bar_open"] += 1
        elif all(
            int(getattr(s, "ts")) <= bar_ts
            and int(getattr(s, "seen_ts")) <= bar_ts
            and bar_ts - int(getattr(s, "ts")) > max_liquidity_age_ms
            for s in snapshots if getattr(s, "liquidity_usd", None) is not None
        ) and any(getattr(s, "liquidity_usd", None) is not None for s in snapshots):
            reasons["stale_snapshot"] += 1
        else:
            reasons["mixed_or_invalid_candidates"] += 1
    return {
        "bar_count": len(bars),
        "matching_snapshot_count": len(snapshots),
        "bars_with_eligible_snapshot": covered,
        "bars_without_eligible_snapshot": len(bars) - covered,
        "unmatched_bar_reasons": reasons,
    }


def audit_record_coverage(
    provider_bars: Iterable[object],
    liquidity_snapshots: Iterable[object],
    *,
    max_liquidity_age_ms: int = 60_000,
    bar_interval_ms: int = 60_000,
) -> dict:
    """Summarize point-in-time liquidity coverage per token/pool.

    The latest known snapshot is used only when both its event and ingestion
    timestamps precede the bar open and its age is within the configured cap.
    Gaps are counted rather than interpolated. Horizon readiness means a pool
    has at least horizon/interval + 1 consecutive bars with known liquidity;
    this is necessary, not sufficient, for valid labels.
    """
    if max_liquidity_age_ms < 0 or bar_interval_ms <= 0:
        raise ValueError("age must be non-negative and interval must be positive")

    raw_bars = list(provider_bars)
    snapshots = list(liquidity_snapshots)
    keys = sorted({
        (str(getattr(bar, "chain", "")), str(getattr(bar, "token")), str(getattr(bar, "pool")))
        for bar in raw_bars
    })
    pool_reports = []
    for chain, token, pool in keys:
        selected = [
            bar for bar in raw_bars
            if getattr(bar, "chain", "") == chain
            and getattr(bar, "token", None) == token
            and getattr(bar, "pool", None) == pool
        ]
        token_key = f"{chain}:{token}" if chain else token
        joined = price_bars_from_point_in_time_records(
            selected, snapshots, token_key=token_key, pool_key=pool,
            max_liquidity_age_ms=max_liquidity_age_ms,
        )
        join_diagnostics = _liquidity_join_diagnostics(
            selected, snapshots, chain=chain, token=token, pool=pool,
            max_liquidity_age_ms=max_liquidity_age_ms,
        )
        gaps = sum(
            1 for left, right in zip(joined, joined[1:])
            if right.ts_ms - left.ts_ms > bar_interval_ms
        )
        known = sum(bar.liquidity_usd is not None for bar in joined)
        longest = _max_contiguous_liquid_bars(joined, bar_interval_ms)
        span = joined[-1].ts_ms - joined[0].ts_ms if len(joined) > 1 else 0
        pool_reports.append({
            "chain": chain,
            "token": token_key,
            "pool": pool,
            "bar_count": len(joined),
            "liquidity_known_bar_count": known,
            "liquidity_known_share": known / len(joined) if joined else None,
            "bar_gap_count": gaps,
            "span_ms": span,
            "max_contiguous_liquid_bars": longest,
            "liquidity_join_diagnostics": join_diagnostics,
            "horizon_readiness": {
                str(horizon): {
                    "minimum_contiguous_liquid_bars": horizon // bar_interval_ms + 1,
                    "sufficient_contiguous_bars": longest >= horizon // bar_interval_ms + 1,
                }
                for horizon in CANDIDATE_HORIZONS_MS
            },
        })

    total_bars = sum(row["bar_count"] for row in pool_reports)
    total_known = sum(row["liquidity_known_bar_count"] for row in pool_reports)
    return {
        "audit_version": "1.1.0",
        "max_liquidity_age_ms": max_liquidity_age_ms,
        "bar_interval_ms": bar_interval_ms,
        "token_count": len({(row["chain"], row["token"]) for row in pool_reports}),
        "token_pool_count": len(pool_reports),
        "bar_count": total_bars,
        "liquidity_known_bar_count": total_known,
        "liquidity_known_share": total_known / total_bars if total_bars else None,
        "pools_sufficient_by_horizon": {
            str(horizon): sum(
                row["horizon_readiness"][str(horizon)]["sufficient_contiguous_bars"]
                for row in pool_reports
            )
            for horizon in CANDIDATE_HORIZONS_MS
        },
        "pools": pool_reports,
        "warning": (
            "Readiness is necessary, not sufficient. OHLCV bars and liquidity "
            "coverage do not prove executable fills or predictive performance. "
            "Archive counts are not independent-token sample sizes."
        ),
    }


def audit_eligible_archives(
    *,
    max_liquidity_age_ms: int = 60_000,
    bar_interval_ms: int = 60_000,
) -> dict:
    """Audit each independently eligible archive separately; never merge them."""
    reports = []
    excluded = []
    archives, excluded = phase3c_data.eligible_archives()
    for archive in archives:
        records, _normalization_report = normalize(str(archive))
        bars = [record for record in records if isinstance(record, ProviderBar)]
        snapshots = [record for record in records if isinstance(record, PoolSnapshot)]
        report = audit_record_coverage(
            bars, snapshots, max_liquidity_age_ms=max_liquidity_age_ms,
            bar_interval_ms=bar_interval_ms,
        )
        reports.append({
            "archive": archive.name,
            "provider_bar_count": len(bars),
            "liquidity_snapshot_count": len(snapshots),
            **report,
        })
    return {
        "audit_version": "1.0.0",
        "archive_count": len(reports),
        "archives": reports,
        "excluded_archives": excluded,
        "note": "Archives are reported independently; cross-archive token overlap is not silently deduplicated here.",
    }


def main() -> None:
    print(json.dumps(audit_eligible_archives(), indent=2, sort_keys=True))


if __name__ == "__main__":
    main()
