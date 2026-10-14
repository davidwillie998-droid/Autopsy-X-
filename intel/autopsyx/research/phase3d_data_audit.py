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
        (str(getattr(bar, "token")), str(getattr(bar, "pool")))
        for bar in raw_bars
    })
    pool_reports = []
    for token, pool in keys:
        selected = [
            bar for bar in raw_bars
            if getattr(bar, "token", None) == token and getattr(bar, "pool", None) == pool
        ]
        joined = price_bars_from_point_in_time_records(
            selected, snapshots, token_key=token, pool_key=pool,
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
            "token": token,
            "pool": pool,
            "bar_count": len(joined),
            "liquidity_known_bar_count": known,
            "liquidity_known_share": known / len(joined) if joined else None,
            "bar_gap_count": gaps,
            "span_ms": span,
            "max_contiguous_liquid_bars": longest,
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
        "audit_version": "1.0.0",
        "max_liquidity_age_ms": max_liquidity_age_ms,
        "bar_interval_ms": bar_interval_ms,
        "token_count": len({row["token"] for row in pool_reports}),
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
