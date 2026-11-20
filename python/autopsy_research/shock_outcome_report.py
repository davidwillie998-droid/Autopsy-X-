"""Cluster-bootstrap summary for AUTOPSY X shock outcome ledger.

Usage:
  python -m python.autopsy_research.shock_outcome_report events.sqlite --output report.csv

Confidence intervals resample event-day clusters, not individual horizon rows.
This reduces (but does not eliminate) dependence from multiple events on one
trading day. Overlapping event windows across days and serial dependence still
require walk-forward / block-bootstrap research before inference.
"""
from __future__ import annotations

import argparse
import csv
import json
import random
import sqlite3
import statistics
from collections import defaultdict
from datetime import datetime, timezone
from pathlib import Path
from zoneinfo import ZoneInfo, ZoneInfoNotFoundError


def percentile(values: list[float], q: float) -> float:
    ordered = sorted(values)
    if not ordered:
        return float("nan")
    position = (len(ordered) - 1) * q
    lo = int(position)
    hi = min(lo + 1, len(ordered) - 1)
    return ordered[lo] + (ordered[hi] - ordered[lo]) * (position - lo)


def load_outcomes(database: str) -> list[dict]:
    connection = sqlite3.connect(database)
    try:
        rows = connection.execute("SELECT payload FROM outcomes").fetchall()
    finally:
        connection.close()
    return [json.loads(row[0]) for row in rows]


def cluster_bootstrap_ci(
    records: list[dict], iterations: int = 2000, seed: int = 17,
    cluster_timezone: str = "UTC",
) -> tuple[float, float]:
    zone = ZoneInfo(cluster_timezone)
    clusters: dict[str, list[float]] = defaultdict(list)
    for row in records:
        day = datetime.fromtimestamp(int(row["event_timestamp"]), tz=zone).date().isoformat()
        clusters[day].append(float(row["directional_return_pct"]))
    keys = sorted(clusters)
    if len(keys) < 2:
        return float("nan"), float("nan")
    rng = random.Random(seed)
    estimates = []
    for _ in range(iterations):
        sampled = [rng.choice(keys) for _ in keys]
        values = [value for key in sampled for value in clusters[key]]
        if values:
            estimates.append(statistics.mean(values))
    return percentile(estimates, 0.025), percentile(estimates, 0.975)


def summarize(
    records: list[dict], iterations: int = 2000, cluster_timezone: str = "UTC"
) -> list[dict]:
    groups: dict[tuple, list[dict]] = defaultdict(list)
    for row in records:
        onset = float(row.get("onset_magnitude_atr", 0.0))
        severity = "<2 ATR" if onset < 2 else "2-3 ATR" if onset < 3 else ">=3 ATR"
        key = (
            row.get("symbol"), row.get("timeframe"), int(row.get("horizon_bars", 0)),
            int(row.get("direction", 0)), row.get("onset_regime") or "UNKNOWN", severity,
        )
        groups[key].append(row)

    output = []
    for key, rows in sorted(groups.items(), key=lambda item: str(item[0])):
        returns = [float(r["directional_return_pct"]) for r in rows]
        lower, upper = cluster_bootstrap_ci(
            rows, iterations=iterations, cluster_timezone=cluster_timezone
        )
        output.append({
            "symbol": key[0], "timeframe": key[1], "horizon_bars": key[2],
            "direction": key[3], "onset_regime": key[4], "severity_bucket": key[5],
            "observations": len(rows),
            "unique_events": len({r["event_id"] for r in rows}),
            "event_days": len({
                datetime.fromtimestamp(int(r["event_timestamp"]), tz=ZoneInfo(cluster_timezone)).date()
                for r in rows
            }),
            "mean_directional_return_pct": statistics.mean(returns),
            "median_directional_return_pct": statistics.median(returns),
            "win_rate_pct": 100.0 * sum(x > 0 for x in returns) / len(returns),
            "mean_mfe_pct": statistics.mean(float(r["max_favourable_excursion_pct"]) for r in rows),
            "mean_mae_pct": statistics.mean(float(r["max_adverse_excursion_pct"]) for r in rows),
            "cluster_bootstrap_mean_ci_2_5_pct": lower,
            "cluster_bootstrap_mean_ci_97_5_pct": upper,
        })
    return output


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("database", help="SQLite ledger created by ShockEventLedger")
    parser.add_argument("--output", default="shock_outcome_summary.csv")
    parser.add_argument("--bootstrap-iterations", type=int, default=2000)
    parser.add_argument("--cluster-timezone", default="UTC",
                        help="IANA timezone for event-day clusters, e.g. America/New_York")
    args = parser.parse_args()
    if args.bootstrap_iterations < 100:
        parser.error("--bootstrap-iterations must be at least 100")
    try:
        ZoneInfo(args.cluster_timezone)
    except ZoneInfoNotFoundError:
        parser.error(f"Unknown IANA timezone: {args.cluster_timezone}")
    records = load_outcomes(args.database)
    if not records:
        parser.error("No matured outcomes in the selected database.")
    rows = summarize(
        records, iterations=args.bootstrap_iterations,
        cluster_timezone=args.cluster_timezone,
    )
    with Path(args.output).open("w", newline="", encoding="utf-8") as handle:
        writer = csv.DictWriter(handle, fieldnames=list(rows[0].keys()))
        writer.writeheader()
        writer.writerows(rows)
    print(f"Wrote {len(rows)} grouped summaries from {len(records)} horizon observations to {args.output}")
    print("Returns are gross price-only, before spread, slippage, financing and contract costs.")
    print(f"Bootstrap clusters use {args.cluster_timezone} calendar days.")
    print("Research only: intervals are clustered estimates, not proof of alpha.")


if __name__ == "__main__":
    main()
