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
        if len({bar["time"] for bar in bars}) != len(bars):
            raise ValueError("Duplicate OHLC timestamps within a symbol/timeframe stream")
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
    # A zero HAC variance does not provide a usable standard error.
    # Returning p=0 here would incorrectly label a constant series as significant.
    if variance <= 0:
        return None
    z = avg / math.sqrt(variance / n)
    return math.erfc(abs(z) / math.sqrt(2.0))


MIN_INFERENCE_OBSERVATIONS = 30

def fixed_bucket(value: str, edges: list[float], labels: list[str]) -> str:
    """Assign a numeric value to predeclared, stable half-open buckets."""
    try:
        number_value = float(value)
    except (TypeError, ValueError):
        return "UNAVAILABLE"
    if not math.isfinite(number_value):
        return "UNAVAILABLE"
    for edge, label in zip(edges, labels):
        if number_value < edge:
            return label
    return labels[-1]


def feature_buckets(row: dict) -> dict[str, str]:
    pullback = fixed_bucket(
        row.get("pullback_depth", ""),
        [0.0, 0.25, 0.5, 0.75],
        ["NEGATIVE", "0_TO_025", "025_TO_050", "050_TO_075", "GE_075"],
    )
    body = fixed_bucket(
        row.get("body_ratio", ""),
        [0.25, 0.5, 0.75],
        ["0_TO_025", "025_TO_050", "050_TO_075", "075_TO_100"],
    )
    close = fixed_bucket(
        row.get("close_location", ""),
        [0.2, 0.4, 0.6, 0.8],
        ["0_TO_020", "020_TO_040", "040_TO_060", "060_TO_080", "080_TO_100"],
    )
    impulse_raw = row.get("prior_impulse_direction", "")
    impulse_labels = {"-1": "BEARISH", "0": "NEUTRAL", "1": "BULLISH"}
    return {
        "candle_state": row.get("candle_state", "").strip() or "UNAVAILABLE",
        "prior_impulse": impulse_labels.get(str(impulse_raw).strip(), "UNAVAILABLE"),
        "pullback_depth_bucket": pullback,
        "body_ratio_bucket": body,
        "close_location_bucket": close,
    }


def evaluate(journal_path: Path, ohlc_path: Path, horizons: list[int]) -> tuple[list[dict], dict]:
    bars_by_key = load_bars(ohlc_path)
    index_by_key = {key: {bar["time"]: i for i, bar in enumerate(bars)} for key, bars in bars_by_key.items()}
    journal = read_csv(journal_path)
    output: list[dict] = []
    exclusions: dict[str, int] = defaultdict(int)
    seen = set()
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
            dedupe_key = (symbol, timeframe, stamp)
            if dedupe_key in seen:
                exclusions["duplicate_journal_observation"] += 1
                continue
            seen.add(dedupe_key)
            impulse = number(row, "prior_impulse_direction")
            if impulse not in (-1.0, 0.0, 1.0):
                raise ValueError("prior_impulse_direction must be -1, 0 or 1")
        except (KeyError, ValueError):
            exclusions["invalid_journal_row"] += 1
            continue
        index = index_by_key.get(key, index_by_key.get(("", "" ), {})).get(stamp)
        if index is None:
            exclusions["journal_bar_not_found_in_ohlc"] += 1
            continue
        n_bars = len(bars)
        train_end = int(n_bars * 0.60)
        validation_end = int(n_bars * 0.80)
        if n_bars < 10:
            split = "insufficient_sample"
            split_end = n_bars
        elif index < train_end:
            split = "train"
            split_end = train_end
        elif index < validation_end:
            split = "validation"
            split_end = validation_end
        else:
            split = "test"
            split_end = n_bars
        entry = bars[index]["close"]
        if entry <= 0:
            exclusions["invalid_entry_price"] += 1
            continue
        for horizon in horizons:
            end = index + horizon
            if end >= len(bars):
                exclusions["insufficient_forward_bars"] += 1
                continue
            if end >= split_end:
                exclusions["forward_window_crosses_split_boundary"] += 1
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
                "split": split,
                "horizon_bars": horizon,
                "prior_impulse_direction": int(impulse),
                "raw_forward_return_pct": raw_return * 100.0,
                "directional_mfe_pct": ((highest / entry - 1.0) * 100.0) if impulse > 0 else ((entry / lowest - 1.0) * 100.0 if impulse < 0 else ""),
                "directional_mae_pct": ((lowest / entry - 1.0) * 100.0) if impulse > 0 else ((entry / highest - 1.0) * 100.0 if impulse < 0 else ""),
                "signed_forward_return_pct": raw_return * impulse * 100.0 if impulse else "",
                "directional_hit": int(raw_return * impulse > 0) if impulse else "",
                "candle_state": row.get("candle_state", ""),
                "body_ratio": row.get("body_ratio", ""),
                "close_location": row.get("close_location", ""),
                "pullback_depth": row.get("pullback_depth", ""),
            }
            row_out.update(feature_buckets(row))
            output.append(row_out)

    # The baseline is prior-impulse performance. Each feature is then evaluated
    # independently, avoiding an unplanned multivariate model or tuned thresholds.
    buckets: dict[tuple[str, str, str, int, str, str], list[dict]] = defaultdict(list)
    for row in output:
        base = (row["symbol"], row["timeframe"], row["split"], row["horizon_bars"])
        buckets[base + ("BASELINE", "PRIOR_IMPULSE")].append(row)
        buckets[base + ("IMPULSE_BASELINE", row["prior_impulse"])].append(row)
        for feature in ("candle_state", "pullback_depth_bucket",
                        "body_ratio_bucket", "close_location_bucket"):
            buckets[base + (feature, row[feature])].append(row)
            # Conditional groups compare candle features while holding the
            # prior-impulse direction fixed, reducing directional-mix confounding.
            conditional_value = feature + "=" + row[feature] + "|impulse=" + row["prior_impulse"]
            buckets[base + (feature + "_GIVEN_IMPULSE", conditional_value)].append(row)

    summaries = []
    p_records = []
    for (symbol, timeframe, split, horizon, feature, feature_value), rows in sorted(buckets.items()):
        directional = [row for row in rows if row["signed_forward_return_pct"] != ""]
        signed = [float(row["signed_forward_return_pct"]) for row in directional]
        p_value = newey_west_mean_p(signed) if len(signed) >= MIN_INFERENCE_OBSERVATIONS else None

        # Compare each feature category with its complementary categories,
        # holding symbol, timeframe, split, horizon and impulse direction fixed.
        comparison_feature = feature.removesuffix("_GIVEN_IMPULSE")
        category_value = feature_value.split("|impulse=")[0].split("=", 1)[-1] if feature.endswith("_GIVEN_IMPULSE") else feature_value
        uplift_deltas = []
        uplift_hit_deltas = []
        comparison_n = 0
        if comparison_feature in ("candle_state", "pullback_depth_bucket", "body_ratio_bucket", "close_location_bucket"):
            for direction in (-1, 1):
                subgroup = [r for r in directional if r["prior_impulse_direction"] == direction]
                if not subgroup:
                    continue
                complement = [
                    candidate for candidate in output
                    if candidate["symbol"] == symbol
                    and candidate["timeframe"] == timeframe
                    and candidate["split"] == split
                    and candidate["horizon_bars"] == horizon
                    and candidate["prior_impulse_direction"] == direction
                    and candidate[comparison_feature] != category_value
                ]
                if complement:
                    baseline_mean = mean(float(r["signed_forward_return_pct"]) for r in complement)
                    baseline_hit = 100.0 * mean(int(r["directional_hit"]) for r in complement)
                    subgroup_mean = mean(float(r["signed_forward_return_pct"]) for r in subgroup)
                    subgroup_hit = 100.0 * mean(int(r["directional_hit"]) for r in subgroup)
                    uplift_deltas.extend([subgroup_mean - baseline_mean] * len(subgroup))
                    uplift_hit_deltas.extend([subgroup_hit - baseline_hit] * len(subgroup))
                    comparison_n += len(complement)

        item = {
            "symbol": symbol,
            "feature": feature,
            "feature_value": feature_value,
            "timeframe": timeframe,
            "split": split,
            "horizon_bars": horizon,
            "observations": len(rows),
            "directional_observations": len(directional),
            "mean_raw_forward_return_pct": mean(float(row["raw_forward_return_pct"]) for row in rows),
            "mean_directional_mfe_pct": mean(float(row["directional_mfe_pct"]) for row in rows if row["directional_mfe_pct"] != "") if any(row["directional_mfe_pct"] != "" for row in rows) else None,
            "mean_directional_mae_pct": mean(float(row["directional_mae_pct"]) for row in rows if row["directional_mae_pct"] != "") if any(row["directional_mae_pct"] != "" for row in rows) else None,
            "directional_hit_rate_pct": (100.0 * mean(int(row["directional_hit"]) for row in directional)) if directional else None,
            "mean_signed_forward_return_pct": mean(signed) if signed else None,
            "complementary_baseline_observations": comparison_n,
            "mean_signed_return_uplift_vs_complement_pct": mean(uplift_deltas) if uplift_deltas else None,
            "directional_hit_rate_uplift_vs_complement_pp": mean(uplift_hit_deltas) if uplift_hit_deltas else None,
            "newey_west_p_value": p_value,
            "bh_adjusted_p_value": None,
            "inference_status": (
                "DESCRIPTIVE_ONLY_BELOW_30_DIRECTIONAL_OBSERVATIONS"
                if len(signed) < MIN_INFERENCE_OBSERVATIONS
                else "DESCRIPTIVE_ONLY_UNDEFINED_HAC_VARIANCE"
                if p_value is None
                else "EXPLORATORY_HAC_NOT_CONFIRMATORY"
            ),
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
        "split_policy": "For streams with at least 10 OHLC bars: first 60% train, next 20% validation, final 20% test, with forward windows crossing boundaries purged. Shorter streams are labelled insufficient_sample and are descriptive only.",
        "feature_policy": "Predeclared fixed bins: pullback depth <0, [0,.25), [.25,.50), [.50,.75), >=.75; body ratio [0,.25), [.25,.50), [.50,.75), [.75,1]; close location [0,.20), [.20,.40), [.40,.60), [.60,.80), [.80,1]. Exact candle-state labels are preserved. Each feature is reported both unconditionally and conditional on prior-impulse direction, alongside overall and direction-stratified impulse baselines.",
        "minimum_directional_observations_for_inference": MIN_INFERENCE_OBSERVATIONS,
        "timestamp_policy": "Journal and OHLC timestamps are parsed as naive wall-clock values. They must use the same broker/server timezone; UTC and broker-local timestamps must not be mixed.",
        "interpretation": (
            "Forward OHLC movement only. Not net trading PnL, not a trade simulation, "
            "and not evidence of causality. Overlapping horizons and serial dependence "
            "remain limitations. HAC p-values are suppressed below 30 directional observations and remain exploratory above that threshold. Feature groups are univariate descriptions, not proof of incremental predictive value. Train is exploratory, validation is for selection, and test must remain untouched until the analysis plan is frozen."
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
            "bar_time", "symbol", "timeframe", "split", "horizon_bars", "prior_impulse_direction",
            "raw_forward_return_pct", "directional_mfe_pct", "directional_mae_pct", "signed_forward_return_pct",
            "directional_hit", "candle_state", "body_ratio", "close_location", "pullback_depth",
            "prior_impulse", "pullback_depth_bucket", "body_ratio_bucket", "close_location_bucket"
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
