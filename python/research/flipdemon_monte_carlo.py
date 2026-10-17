#!/usr/bin/env python3
"""Offline, report-only Monte Carlo validation for FLIPDEMON EXTREME.

Input CSV must contain one chronologically ordered row per completed trade and
an r_multiple column measured net of commission, spread, and slippage. This
module does not connect to MT5 and does not claim to replay the EA's signal or
pyramiding logic. It compares IID trade bootstrap with stationary bootstrap
and explicit adverse-cost stresses.
"""
from __future__ import annotations

import argparse
import csv
import json
import math
import random
import statistics
import sys
from dataclasses import asdict, dataclass
from pathlib import Path
from typing import Iterable, Sequence


@dataclass(frozen=True)
class Config:
    paths: int = 20_000
    trades_per_path: int | None = None
    risk_pct: float = 0.25
    drawdown_limit_pct: float = 8.0
    ruin_equity_pct: float = 50.0
    mean_block_length: float = 8.0
    adverse_cost_r: float = 0.0
    seed: int = 20261017


def _validate_returns(values: Sequence[float]) -> None:
    if len(values) < 20:
        raise ValueError(f"At least 20 observed trades required; got {len(values)}")
    if any(not math.isfinite(x) for x in values):
        raise ValueError("Trade R-multiples must all be finite numbers")


def load_trade_r(path: Path, column: str = "r_multiple") -> list[float]:
    """Load chronologically ordered, net-of-cost trade R-multiples from CSV."""
    with path.open("r", newline="", encoding="utf-8-sig") as handle:
        reader = csv.DictReader(handle)
        if not reader.fieldnames or column not in reader.fieldnames:
            raise ValueError(f"CSV must contain a '{column}' column")
        values = [float(row[column]) for row in reader if row.get(column, "").strip()]
    _validate_returns(values)
    return values


def iid_sample(values: Sequence[float], n: int, rng: random.Random) -> list[float]:
    return [values[rng.randrange(len(values))] for _ in range(n)]


def stationary_sample(
    values: Sequence[float], n: int, mean_block_length: float, rng: random.Random
) -> list[float]:
    """Politis-Romano stationary bootstrap with circular continuation.

    Each next observation starts a new random block with probability 1/L;
    otherwise the prior block continues at the next circular observation.
    """
    if mean_block_length < 1.0 or not math.isfinite(mean_block_length):
        raise ValueError("mean_block_length must be finite and >= 1")
    size = len(values)
    index = rng.randrange(size)
    sample: list[float] = []
    restart_probability = 1.0 / mean_block_length
    for _ in range(n):
        if sample and rng.random() < restart_probability:
            index = rng.randrange(size)
        sample.append(values[index])
        index = (index + 1) % size
    return sample


def equity_path(
    returns_r: Sequence[float],
    risk_pct: float,
    adverse_cost_r: float = 0.0,
    ruin_equity_pct: float = 50.0,
) -> dict[str, float | int | bool]:
    """Compound equity using a fixed fraction of current equity per trade.

    Net trade return = R multiple * risk fraction. Risk is clamped only by input
    validation, not broker-specific volume/stop rules. This is a simplified
    account-path model, not a substitute for exact EA replay.
    """
    if not (0 < risk_pct <= 2.0):
        raise ValueError("risk_pct must be > 0 and <= 2.0 percent")
    if adverse_cost_r < 0 or not math.isfinite(adverse_cost_r):
        raise ValueError("adverse_cost_r must be finite and >= 0")
    if not (0 < ruin_equity_pct < 100) or not math.isfinite(ruin_equity_pct):
        raise ValueError("ruin_equity_pct must be finite and between 0 and 100")
    risk_fraction = risk_pct / 100.0
    equity = peak = 1.0
    max_dd_pct = 0.0
    losing_streak = current_streak = 0
    for raw_r in returns_r:
        net_r = raw_r - adverse_cost_r
        # A trade cannot lose more than current equity in this simplified model.
        factor = max(0.0, 1.0 + risk_fraction * net_r)
        equity *= factor
        peak = max(peak, equity)
        dd = 100.0 * (peak - equity) / peak if peak else 100.0
        max_dd_pct = max(max_dd_pct, dd)
        if net_r < 0:
            current_streak += 1
            losing_streak = max(losing_streak, current_streak)
        else:
            current_streak = 0
    return {
        "final_equity_pct_initial": 100.0 * equity,
        "max_drawdown_pct": max_dd_pct,
        "longest_losing_streak": losing_streak,
        "ruin_threshold_breach": equity <= ruin_equity_pct / 100.0,
    }


def percentile(values: Sequence[float], p: float) -> float:
    if not values:
        raise ValueError("percentile requires non-empty values")
    ordered = sorted(values)
    index = (len(ordered) - 1) * p
    lo = math.floor(index)
    hi = math.ceil(index)
    if lo == hi:
        return ordered[lo]
    return ordered[lo] * (hi - index) + ordered[hi] * (index - lo)


def binomial_upper_95_zero_or_general(breaches: int, trials: int) -> float:
    """Wilson upper confidence bound for a binomial breach probability."""
    if trials <= 0 or not 0 <= breaches <= trials:
        raise ValueError("require trials > 0 and 0 <= breaches <= trials")
    z = 1.959963984540054
    p = breaches / trials
    den = 1.0 + z * z / trials
    center = p + z * z / (2.0 * trials)
    radius = z * math.sqrt((p * (1.0 - p) / trials) + z * z / (4.0 * trials * trials))
    return min(1.0, (center + radius) / den)


def run_simulations(values: Sequence[float], config: Config, method: str) -> dict:
    _validate_returns(values)
    if config.paths < 100:
        raise ValueError("paths must be >= 100")
    if config.trades_per_path is not None and config.trades_per_path < 1:
        raise ValueError("trades_per_path must be >= 1")
    if not (0 < config.drawdown_limit_pct < 100):
        raise ValueError("drawdown_limit_pct must be between 0 and 100")
    if not (0 < config.ruin_equity_pct < 100):
        raise ValueError("ruin_equity_pct must be between 0 and 100")
    if method not in {"iid", "stationary"}:
        raise ValueError("method must be iid or stationary")

    rng = random.Random(config.seed)
    n = config.trades_per_path or len(values)
    dds: list[float] = []
    equities: list[float] = []
    streaks: list[float] = []
    breach_count = ruin_count = 0
    for _ in range(config.paths):
        if method == "iid":
            sample = iid_sample(values, n, rng)
        else:
            sample = stationary_sample(values, n, config.mean_block_length, rng)
        result = equity_path(
            sample, config.risk_pct, config.adverse_cost_r, config.ruin_equity_pct
        )
        dd = float(result["max_drawdown_pct"])
        eq = float(result["final_equity_pct_initial"])
        dds.append(dd)
        equities.append(eq)
        streaks.append(float(result["longest_losing_streak"]))
        breach_count += dd >= config.drawdown_limit_pct
        ruin_count += eq <= config.ruin_equity_pct
    dd_tail_cut = percentile(dds, 0.95)
    dd_tail = [x for x in dds if x >= dd_tail_cut]
    return {
        "method": method,
        "config": asdict(config),
        "observed_trades": len(values),
        "simulated_trades_per_path": n,
        "paths": config.paths,
        "max_drawdown_pct": {
            "median": percentile(dds, 0.50),
            "p95": percentile(dds, 0.95),
            "p99": percentile(dds, 0.99),
            "worst_observed_simulation": max(dds),
            "expected_shortfall_worst_5pct": statistics.fmean(dd_tail),
        },
        "final_equity_pct_initial": {
            "p05": percentile(equities, 0.05),
            "median": percentile(equities, 0.50),
            "p95": percentile(equities, 0.95),
        },
        "longest_losing_streak": {
            "median": percentile(streaks, 0.50),
            "p95": percentile(streaks, 0.95),
            "worst_observed_simulation": max(streaks),
        },
        "drawdown_limit_pct": config.drawdown_limit_pct,
        "drawdown_breach_probability_estimate": breach_count / config.paths,
        "drawdown_breach_probability_wilson_95_upper": binomial_upper_95_zero_or_general(
            breach_count, config.paths
        ),
        "ruin_equity_threshold_pct": config.ruin_equity_pct,
        "ruin_threshold_probability_estimate": ruin_count / config.paths,
        "ruin_threshold_probability_wilson_95_upper": binomial_upper_95_zero_or_general(
            ruin_count, config.paths
        ),
        "warning": (
            "Trade-outcome bootstrap only: this does not replay EA signals, VWAP exits, "
            "dynamic pyramiding, broker fills, margin, gaps, or portfolio correlation. "
            "Confidence bounds are conditional on the resampling model and observed data."
        ),
    }


def main(argv: Iterable[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("csv", type=Path, help="chronological trade CSV with net r_multiple")
    parser.add_argument("--column", default="r_multiple")
    parser.add_argument("--paths", type=int, default=20_000)
    parser.add_argument("--trades-per-path", type=int, default=None)
    parser.add_argument("--risk-pct", type=float, default=0.25)
    parser.add_argument("--drawdown-limit-pct", type=float, default=8.0)
    parser.add_argument("--ruin-equity-pct", type=float, default=50.0)
    parser.add_argument("--mean-block-length", type=float, default=8.0)
    parser.add_argument("--adverse-cost-r", type=float, default=0.0,
                        help="extra adverse cost in R per trade; 0 means input is assumed net of costs")
    parser.add_argument("--seed", type=int, default=20261017)
    parser.add_argument("--output", type=Path, default=None)
    args = parser.parse_args(argv)
    try:
        values = load_trade_r(args.csv, args.column)
        config = Config(
            paths=args.paths, trades_per_path=args.trades_per_path, risk_pct=args.risk_pct,
            drawdown_limit_pct=args.drawdown_limit_pct, ruin_equity_pct=args.ruin_equity_pct,
            mean_block_length=args.mean_block_length, adverse_cost_r=args.adverse_cost_r,
            seed=args.seed,
        )
        reports = [
            run_simulations(values, config, "iid"),
            run_simulations(values, config, "stationary"),
        ]
        payload = {
            "schema_version": 1,
            "report_only": True,
            "source_csv": str(args.csv),
            "cost_assumption": (
                "input R-multiples must already be net of spread, commission and slippage; "
                "adverse_cost_r is an additional per-trade stress deduction"
            ),
            "reports": reports,
        }
        rendered = json.dumps(payload, indent=2, sort_keys=True)
        if args.output:
            args.output.write_text(rendered + "\n", encoding="utf-8")
        else:
            print(rendered)
        return 0
    except (OSError, ValueError, csv.Error) as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
