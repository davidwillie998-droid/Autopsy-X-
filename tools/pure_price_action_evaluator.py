#!/usr/bin/env python3
"""Offline forward-outcome evaluator for AUTOPSY X pure-price-action journals.

The evaluator requires:
  1) MT5 journal CSV emitted by CPurePriceAction.
  2) OHLC CSV with timestamp, open, high, low, close columns.
Optional symbol and timeframe columns restrict/match instruments.

This measures subsequent market movement, not broker-executable PnL.
"""
from __future__ import annotations

import argparse
import csv
import json
import math
from collections import defaultdict
from datetime import datetime
from pathlib import Path
from statistics import mean


TIME_FORMATS = (
    "%Y.%m.%d %H:%M",
    "%Y-%m-%d %H:%M:%S",
    "%Y-%m-%dT%H:%M:%S",
    "%Y-%m-%d %H:%M",
)


def parse_time(value: str) -> datetime:
    value = value.strip()
    for fmt in TIME_FORMATS:
        try:
            return datetime.strptime(value, fmt)
        except ValueError:
            pass
    raise ValueError("Unsupported timestamp: " + value)


def read_csv(path: Path) -> list[dict[str, str]]:
    with path.open("r", newline="", encoding="utf-8-sig") as handle:
        return list(csv.DictReader(handle))


def number(row: dict[str, str], key: str) -> float:
    value = float(row[key])
    if not math.isfinite(value):
        raise ValueError("Non-finite " + key)
    return value


def load_bars(path: Path) -> dict[tuple[str, str], list[dict]]:
    grouped: dict[tuple[str, str], list[dict]] = defaultdict(list)
    for raw in read_csv(path):
        stamp_key = "timestamp" if "timestamp" in raw else "bar_time"
        stamp = parse_time(raw[stamp_key])
        symbol = raw.get("symbol", "").strip()
        timeframe = raw.get("timeframe", "").strip()
        bar = {
            "time": stamp,
            "open": number(raw, "open"),
            "high": number(raw, "high"),
            "low": number(raw, "low"),
            "close": number(raw, "close"),
        }
        if bar["low"] > min(bar["open"], bar["close"]) or bar["high"] < max(bar["open"], bar["close"]) or bar["high"] < bar["low"]:
            raise ValueError("Invalid OHLC at " + str(stamp))
        grouped[(symbol, timeframe)].append(bar)
    for bars in grouped.values():
        bars.sort(key=lambda item: item["time"])
    return grouped


def benjamini_hochberg(p_values: list[float]) -> list[float]:
    """Return monotone Benjamini-Hochberg adjusted p-values."""
    count = len(p_values)
    order = sorted(range(count), key=lambda i: p_values[i])
    adjusted = [1.0] * count
    running = 1.0
    for reverse_rank in range(count - 1, -1, -1):
        index = order[reverse_rank]
        rank = reverse_rank + 1
        running = min(running, p_values[index] * count / rank)
        adjusted[index] = min(1.0, running)
    return adjusted


def newey_west_mean_p(values: list[float]) -> float | None:
    """Two-sided normal-approximation p-value using a Newey-West mean variance."""
    n = len(values)
    if n < 10:
        return None
    avg = mean(values)
    centered = [value - avg for value in values]
    lag = max(1, int(4 * (n / 100) ** (2 / 9)))
    gamma0 = sum(x * x for x in centered) / n
    variance = gamma0
    for k in range(1, min(lag, n - 1) + 1):
        covariance = sum(centered[t] * centered[t-k] for t in range(k, n)) / n
        weight = 1.0 - k / (lag + 1.0)
        variance += 2.0 * weight * covariance
    if variance <= 0:
        return 1.0 if avg == 0 else 0.0
    z = avg / math.sqrt(variance / n)
    return math.erfc(abs(z) / math.sqrt(2.0))


def evaluate(journal_path: Path, ohlc_path: Path, horizons: list[int]) -> tuple[list[dict], dict]:
    bars_by_key = load_bars(ohlc_path)
    journal = read_csv(journal_path)
    output: list[dict] = []
    exclusions: dict[str, int] = defaultdict(int)
    for row in journal:
        symbol = row.get("symbol", "").strip()
        timeframe = row.get("timeframe", "").strip()
        key = (symbol, timeframe)
        bars = bars_by_key.get(key)
        if bars is None:
            # Permit a single unlabelled OHLC file for a single journal stream.
            bars = bars_by_key.get(("", ""))
        if not bars:
            exclusions["missing_symbol_timeframe_ohlc"] += 1
            continue
        try:
            stamp = parse_time(row["bar_time"])
            impulse = number(row, "prior_impulse_direction")
        except (KeyError, ValueError):
            exclusions["invalid_journal_row"] += 1
            continue
        index_by_time = {bar["time"]: i for i, bar in enumerate(bars)}
        index = index_by_time.get(stamp)
        if index is None:
            exclusions["journal_bar_not_found_in_ohlc"] += 1
            continue
        entry = bars[index]["close"]
        if entry <= 0:
            exclusions["invalid_entry_price"] += 1
            continue
        for horizon in horizons:
            end = index + horizon
            if end >= len(bars):
                exclusions["insufficient_forward_bars"] += 1
                continue
            future = bars[index + 1:end + 1]
            end_close = future[-1]["close"]
            highest = max(bar["high"] for bar in future)
            lowest = min(bar["low"] for bar in future)
            raw_return = end_close / entry - 1.0
            row_out = {
                "bar_time": stamp.strftime("%Y-%m-%d %H:%M:%S"),
                "symbol": symbol,
                "timeframe": timeframe,
                "horizon_bars": horizon,
                "prior_impulse_direction": int(impulse),
                "raw_forward_return_pct": raw_return * 100.0,
                "mfe_pct": (highest / entry - 1.0) * 100.0,
                "mae_pct": (lowest / entry - 1.0) * 100.0,
                "signed_forward_return_pct": raw_return * impulse * 100.0 if impulse else "",
                "directional_hit": int(raw_return * impulse > 0) if impulse else "",
                "candle_state": row.get("candle_state", ""),
                "body_ratio": row.get("body_ratio", ""),
                "close_location": row.get("close_location", ""),
                "pullback_depth": row.get("pullback_depth", ""),
            }
            output.append(row_out)

    buckets: dict[tuple[str, str, int], list[dict]] = defaultdict(list)
    for row in output:
        buckets[(row["symbol"], row["timeframe"], row["horizon_bars"])].append(row)

    summaries = []
    p_records = []
    for (symbol, timeframe, horizon), rows in sorted(buckets.items()):
        directional = [row for row in rows if row["signed_forward_return_pct"] != ""]
        signed = [float(row["signed_forward_return_pct"]) for row in directional]
        p_value = newey_west_mean_p(signed)
        item = {
            "symbol": symbol,
            "timeframe": timeframe,
            "horizon_bars": horizon,
            "observations": len(rows),
            "directional_observations": len(directional),
            "mean_raw_forward_return_pct": mean(float(row["raw_forward_return_pct"]) for row in rows),
            "mean_mfe_pct": mean(float(row["mfe_pct"]) for row in rows),
            "mean_mae_pct": mean(float(row["mae_pct"]) for row in rows),
            "directional_hit_rate_pct": (100.0 * mean(int(row["directional_hit"]) for row in directional)) if directional else None,
            "mean_signed_forward_return_pct": mean(signed) if signed else None,
            "newey_west_p_value": p_value,
            "bh_adjusted_p_value": None,
            "inference_status": "DESCRIPTIVE_ONLY" if p_value is None else "EXPLORATORY_HAC",
        }
        summaries.append(item)
        if p_value is not None:
            p_records.append((len(summaries) - 1, p_value))

    adjusted = benjamini_hochberg([p for _, p in p_records])
    for (summary_index, _), q_value in zip(p_records, adjusted):
        summaries[summary_index]["bh_adjusted_p_value"] = q_value
    metadata = {
        "journal_rows": len(journal),
        "evaluated_observation_horizons": len(output),
        "exclusions": dict(exclusions),
        "interpretation": (
            "Forward OHLC movement only. Not net trading PnL, not a trade simulation, "
            "and not evidence of causality. Overlapping horizons and serial dependence "
            "remain limitations; confirm findings on chronological holdout data."
        ),
    }
    return output, {"groups": summaries, "metadata": metadata}


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--journal", required=True, type=Path)
    parser.add_argument("--ohlc", required=True, type=Path)
    parser.add_argument("--out", required=True, type=Path)
    parser.add_argument("--horizons", default="1,3,5,10,20")
    args = parser.parse_args()
    horizons = sorted({int(value) for value in args.horizons.split(",")})
    if not horizons or any(value < 1 for value in horizons):
        parser.error("horizons must be positive integers")
    observations, report = evaluate(args.journal, args.ohlc, horizons)
    args.out.mkdir(parents=True, exist_ok=True)
    with (args.out / "price_action_forward_observations.csv").open("w", newline="", encoding="utf-8") as handle:
        writer = csv.DictWriter(handle, fieldnames=list(observations[0]) if observations else [
            "bar_time", "symbol", "timeframe", "horizon_bars", "prior_impulse_direction",
            "raw_forward_return_pct", "mfe_pct", "mae_pct", "signed_forward_return_pct",
            "directional_hit", "candle_state", "body_ratio", "close_location", "pullback_depth"
        ])
        writer.writeheader()
        writer.writerows(observations)
    (args.out / "price_action_forward_summary.json").write_text(
        json.dumps(report, indent=2), encoding="utf-8"
    )
    print(json.dumps(report, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
