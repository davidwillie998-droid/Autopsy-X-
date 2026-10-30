#!/usr/bin/env python3
"""Research-only M15 RSI/relative-momentum ranking harness.

This script reads historical bars and emits diagnostic rankings plus forward-return
labels. It has no MT5, broker, order-send, or position-sizing dependencies.

Required CSV columns:
  timestamp,symbol,market_family,open,high,low,close
Optional point-in-time H1/H4 context columns:
  h1_alignment,h4_alignment  (values must be -1, 0, or +1)

Benchmark map JSON example:
  {"FX":"DXY","METAL":"XAUUSD","EQUITY":"SPY"}

Important: optional H1/H4 alignment must already be aligned to the M15 row using
only the last fully completed higher-timeframe candle. This script cannot infer
that provenance from the values alone; it records the supplied columns as inputs.
"""
from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path
from typing import Any

import numpy as np
import pandas as pd

HORIZONS = (4, 16, 48)
REQUIRED = {"timestamp", "symbol", "market_family", "open", "high", "low", "close"}
WEIGHTS = {
    "relative_performance": 0.35,
    "momentum_consistency": 0.30,
    "rsi_regime": 0.20,
    "trend_alignment": 0.15,
}


def file_sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def wilder_rsi(close: pd.Series, period: int = 14) -> pd.Series:
    """Wilder RSI with the canonical initial SMA seed and recursive smoothing."""
    if period < 1:
        raise ValueError("RSI period must be positive.")
    values = pd.to_numeric(close, errors="coerce").to_numpy(dtype=float)
    result = np.full(values.shape, np.nan, dtype=float)
    if len(values) <= period:
        return pd.Series(result, index=close.index, name=close.name)

    delta = np.diff(values)
    gains = np.maximum(delta, 0.0)
    losses = np.maximum(-delta, 0.0)
    avg_gain = float(np.mean(gains[:period]))
    avg_loss = float(np.mean(losses[:period]))

    def to_rsi(gain: float, loss: float) -> float:
        if gain == 0.0 and loss == 0.0:
            return 50.0
        if loss == 0.0:
            return 100.0
        if gain == 0.0:
            return 0.0
        relative_strength = gain / loss
        return 100.0 - (100.0 / (1.0 + relative_strength))

    result[period] = to_rsi(avg_gain, avg_loss)
    for index in range(period + 1, len(values)):
        avg_gain = ((period - 1) * avg_gain + gains[index - 1]) / period
        avg_loss = ((period - 1) * avg_loss + losses[index - 1]) / period
        result[index] = to_rsi(avg_gain, avg_loss)
    return pd.Series(result, index=close.index, name=close.name)


def _validate_ohlc(frame: pd.DataFrame) -> pd.DataFrame:
    missing = REQUIRED - set(frame.columns)
    if missing:
        raise ValueError(f"Missing required columns: {sorted(missing)}")
    out = frame.copy()
    out["timestamp"] = pd.to_datetime(out["timestamp"], utc=True, errors="coerce")
    if out["timestamp"].isna().any():
        raise ValueError("Invalid timestamps; expected parseable UTC timestamps.")
    for col in ("open", "high", "low", "close"):
        out[col] = pd.to_numeric(out[col], errors="coerce")
    if out[["open", "high", "low", "close"]].isna().any().any():
        raise ValueError("Missing or non-numeric OHLC values.")
    if (out[["open", "high", "low", "close"]] <= 0.0).any().any():
        raise ValueError("OHLC values must be positive.")
    invalid = (
        (out["high"] < out[["open", "close", "low"]].max(axis=1))
        | (out["low"] > out[["open", "close", "high"]].min(axis=1))
    )
    if invalid.any():
        raise ValueError(f"Invalid OHLC relationships in {int(invalid.sum())} rows.")
    if out[["symbol", "market_family"]].isna().any().any():
        raise ValueError("symbol and market_family cannot be null.")
    out["symbol"] = out["symbol"].astype(str).str.strip()
    out["market_family"] = out["market_family"].astype(str).str.strip()
    if (out["symbol"] == "").any() or (out["market_family"] == "").any():
        raise ValueError("symbol and market_family cannot be blank.")
    if out.duplicated(["symbol", "timestamp"]).any():
        raise ValueError("Duplicate symbol/timestamp rows.")
    return out.sort_values(["symbol", "timestamp"]).reset_index(drop=True)


def load_bars(path: Path) -> pd.DataFrame:
    return _validate_ohlc(pd.read_csv(path))


def _cross_sectional_percentile(values: pd.Series) -> pd.Series:
    return values.rank(method="average", pct=True)


def build_rankings(bars: pd.DataFrame, benchmark_map: dict[str, str]) -> pd.DataFrame:
    """Build point-in-time cross-sectional ranks and strictly-forward labels."""
    x = _validate_ohlc(bars)
    if not benchmark_map:
        raise ValueError("Benchmark map is empty.")
    missing_families = set(x["market_family"].unique()) - set(benchmark_map)
    if missing_families:
        raise ValueError(f"Benchmark mapping missing market families: {sorted(missing_families)}")

    if ("h1_alignment" in x.columns) != ("h4_alignment" in x.columns):
        raise ValueError("Provide both h1_alignment and h4_alignment, or neither.")

    feature_frames = []
    for (family, symbol), group in x.groupby(["market_family", "symbol"], sort=False):
        group = group.sort_values("timestamp").copy()
        group["rsi_14"] = wilder_rsi(group["close"], 14)
        for horizon in HORIZONS:
            group[f"return_{horizon}"] = group["close"].pct_change(horizon)
            group[f"forward_return_{horizon}"] = (
                group["close"].shift(-horizon) / group["close"] - 1.0
            )
        group["rsi_change_3"] = group["rsi_14"].diff(3)
        feature_frames.append(group)
    x = pd.concat(feature_frames, ignore_index=True)

    group_keys = ["market_family", "timestamp"]
    for family, benchmark_symbol in benchmark_map.items():
        if not isinstance(benchmark_symbol, str) or not benchmark_symbol.strip():
            raise ValueError(f"Invalid benchmark symbol for {family}.")
        benchmark = x[
            (x["market_family"] == family) & (x["symbol"] == benchmark_symbol)
        ][["timestamp"] + [f"return_{h}" for h in HORIZONS]].copy()
        if benchmark.empty:
            raise ValueError(f"Benchmark {benchmark_symbol!r} missing for {family!r}.")
        if benchmark["timestamp"].duplicated().any():
            raise ValueError(f"Benchmark {benchmark_symbol!r} has duplicate timestamps.")
        benchmark = benchmark.rename(
            columns={f"return_{h}": f"benchmark_return_{h}" for h in HORIZONS}
        )
        family_mask = x["market_family"] == family
        joined = x.loc[family_mask, ["timestamp"]].merge(
            benchmark, on="timestamp", how="left", validate="many_to_one"
        )
        for horizon in HORIZONS:
            x.loc[family_mask, f"benchmark_return_{horizon}"] = (
                joined[f"benchmark_return_{horizon}"].to_numpy()
            )

    for horizon in HORIZONS:
        x[f"relative_return_{horizon}"] = (
            x[f"return_{horizon}"] - x[f"benchmark_return_{horizon}"]
        )
        x[f"relative_pct_{horizon}"] = x.groupby(group_keys)[
            f"relative_return_{horizon}"
        ].transform(_cross_sectional_percentile)

    # Horizon weights are fixed ex ante; all required values must exist.
    x["relative_performance"] = (
        0.20 * x["relative_pct_4"]
        + 0.50 * x["relative_pct_16"]
        + 0.30 * x["relative_pct_48"]
    )

    positive_horizons = pd.concat(
        [(x[f"return_{h}"] > 0.0).astype(float) for h in HORIZONS], axis=1
    )
    x["momentum_consistency_raw"] = positive_horizons.mean(axis=1)
    x["momentum_consistency"] = x.groupby(group_keys)[
        "momentum_consistency_raw"
    ].transform(_cross_sectional_percentile)

    # Bullish rotation score: RSI above 50 is constructive; a rising RSI adds
    # confirmation. This is deliberately a simple baseline, not an optimized rule.
    bullish_regime = ((x["rsi_14"] - 50.0) / 15.0).clip(0.0, 1.0)
    overbought_penalty = ((85.0 - x["rsi_14"]) / 10.0).clip(0.0, 1.0)
    x["rsi_regime_raw"] = (
        bullish_regime
        * overbought_penalty
        * (0.75 + 0.25 * (x["rsi_change_3"] > 0.0).astype(float))
    )
    x["rsi_regime"] = x.groupby(group_keys)["rsi_regime_raw"].transform(
        _cross_sectional_percentile
    )

    htf_present = {"h1_alignment", "h4_alignment"}.issubset(x.columns)
    if htf_present:
        for col in ("h1_alignment", "h4_alignment"):
            x[col] = pd.to_numeric(x[col], errors="coerce")
            valid = x[col].dropna().isin([-1, 0, 1])
            if not valid.all():
                raise ValueError(f"{col} values must be -1, 0, +1, or missing.")
        x["trend_alignment_raw"] = (
            (x["h1_alignment"] + x["h4_alignment"]) / 2.0 + 1.0
        ) / 2.0
        x["trend_alignment"] = x.groupby(group_keys)[
            "trend_alignment_raw"
        ].transform(_cross_sectional_percentile)
        required = [
            "relative_performance",
            "momentum_consistency",
            "rsi_regime",
            "trend_alignment",
        ]
        x["composite_score"] = sum(
            WEIGHTS[name] * x[name] for name in WEIGHTS
        )
        x["score_status"] = np.where(
            x[required].notna().all(axis=1), "SCORED", "NO_RANK"
        )
        # A cross-sectional rank is not meaningful with fewer than three eligible
        # instruments. Fail closed rather than awarding a singleton a perfect rank.
        eligible_count = x.groupby(group_keys)["composite_score"].transform("count")
        x.loc[eligible_count < 3, "composite_score"] = np.nan
        x.loc[eligible_count < 3, "score_status"] = "NO_RANK"
    else:
        # Never fabricate HTF context from M15 data.
        x["trend_alignment"] = np.nan
        x["composite_score"] = np.nan
        x["score_status"] = "BASELINE_ONLY_HTF_MISSING"

    x["composite_rank"] = x.groupby(group_keys)["composite_score"].rank(
        method="average", ascending=False
    )
    x["simple_momentum_rank"] = x.groupby(group_keys)["relative_return_16"].rank(
        method="average", ascending=False
    )

    def classify(row: pd.Series) -> str:
        if row["score_status"] != "SCORED":
            return "NO_RANK"
        score = row["composite_score"]
        if score >= 0.80:
            return "LEADING"
        if score >= 0.60:
            return "STRENGTHENING"
        if score <= 0.20:
            return "LAGGING"
        if score <= 0.40:
            return "WEAKENING"
        return "NEUTRAL"

    x["state"] = x.apply(classify, axis=1)
    return x.sort_values(
        ["timestamp", "market_family", "composite_rank", "symbol"],
        na_position="last",
    ).reset_index(drop=True)


def _rank_spread(frame: pd.DataFrame, horizon: int) -> dict[str, Any]:
    label = f"forward_return_{horizon}"
    rows = frame.dropna(subset=["composite_rank", label]).copy()
    if rows.empty:
        return {"observations": 0, "top_mean": None, "bottom_mean": None, "spread": None}
    # Compute top/bottom quintiles within each family/timestamp cross-section.
    rows["rank_pct"] = rows.groupby(["market_family", "timestamp"])[
        "composite_rank"
    ].rank(method="average", pct=True, ascending=False)
    top = rows[rows["rank_pct"] <= 0.20][label]
    bottom = rows[rows["rank_pct"] >= 0.80][label]
    top_mean = float(top.mean()) if len(top) else None
    bottom_mean = float(bottom.mean()) if len(bottom) else None
    return {
        "observations": int(len(rows)),
        "top_count": int(len(top)),
        "bottom_count": int(len(bottom)),
        "top_mean": top_mean,
        "bottom_mean": bottom_mean,
        "spread": (top_mean - bottom_mean)
        if top_mean is not None and bottom_mean is not None else None,
    }


def summarize(results: pd.DataFrame) -> dict[str, Any]:
    return {
        "verdict": "NOT_APPROVED",
        "execution_authority": "NONE",
        "warning": "Forward returns are research labels, not net strategy returns.",
        "rows": int(len(results)),
        "symbols": int(results["symbol"].nunique()),
        "market_families": sorted(results["market_family"].unique().tolist()),
        "score_status_counts": {
            str(k): int(v)
            for k, v in results["score_status"].value_counts(dropna=False).items()
        },
        "forward_rank_spreads": {
            str(h): _rank_spread(results, h) for h in HORIZONS
        },
        "cost_model": "NOT_APPLIED",
        "walk_forward_validation": "NOT_RUN",
    }


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--input", required=True, type=Path)
    parser.add_argument("--benchmark-map", required=True, type=Path)
    parser.add_argument("--output-dir", required=True, type=Path)
    args = parser.parse_args()

    if not args.input.is_file() or not args.benchmark_map.is_file():
        parser.error("Input CSV and benchmark-map JSON must exist.")
    benchmark_map = json.loads(args.benchmark_map.read_text(encoding="utf-8"))
    if not isinstance(benchmark_map, dict):
        parser.error("Benchmark map must be a JSON object of family to symbol.")

    bars = load_bars(args.input)
    results = build_rankings(bars, benchmark_map)
    args.output_dir.mkdir(parents=True, exist_ok=True)
    results.to_csv(args.output_dir / "rsi_rotation_observations.csv", index=False)
    report = summarize(results)
    report["input_sha256"] = file_sha256(args.input)
    report["benchmark_map"] = benchmark_map
    report["rows_with_htf_context"] = int(
        (results["score_status"] == "SCORED").sum()
    )
    report["strategy_version"] = "rsi-rotation-baseline-v0.1"
    (args.output_dir / "summary.json").write_text(
        json.dumps(report, indent=2, sort_keys=True, allow_nan=False) + "\n",
        encoding="utf-8",
    )
    print(json.dumps(report, indent=2, sort_keys=True, allow_nan=False))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
