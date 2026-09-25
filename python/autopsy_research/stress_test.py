"""Adversarial stress testing of a returns series.

ENGINEERING DESIGN, not paper-sourced - the source paper's own finding (64%
of the hedge funds it studied experienced losses exceeding TWICE their past
maximum drawdown during the 2008 crisis) MOTIVATES stress testing a
strategy's own historical envelope rather than trusting it under changed
conditions - it does not supply a stress-test methodology or shock
magnitudes, which are this module's own design choices, documented as such
below.

Each function here takes a returns series and returns a MODIFIED series
representing one adversarial scenario - it never mutates the input in place,
and never claims a stressed scenario is a prediction, only a "what if"
sensitivity check.
"""
from __future__ import annotations

from dataclasses import dataclass

import numpy as np
import pandas as pd

from .backtest import max_drawdown_from_returns, sharpe_ratio


def apply_single_shock(returns: pd.Series, shock_pct: float, shock_index: int) -> pd.Series:
    """Returns a copy of `returns` with one additional adverse return of
    `shock_pct` (e.g. -0.10 for a sudden -10% shock) inserted immediately
    BEFORE position `shock_index` - simulating a single black-swan event
    landing mid-history. `shock_pct` should be negative for an adverse shock;
    a positive value is accepted (an adversarial "favorable" scenario is a
    valid sensitivity check too) but not the intended default use."""
    if not 0 <= shock_index <= len(returns):
        raise ValueError("shock_index out of range")
    shocked = pd.concat(
        [returns.iloc[:shock_index], pd.Series([shock_pct]), returns.iloc[shock_index:]],
        ignore_index=True,
    )
    return shocked


def apply_cost_multiplier(returns: pd.Series, cost_multiplier: float, base_cost_per_trade: float) -> pd.Series:
    """Simulates widening spreads/commissions: subtracts
    `base_cost_per_trade * (cost_multiplier - 1.0)` from every return, i.e.
    the EXTRA cost above whatever cost is already embedded in `returns`
    (this function does not know or assume what cost is already baked in -
    it only adds the incremental stress).

    cost_multiplier=1.0 is a no-op (returns unchanged); cost_multiplier=2.0
    means "costs doubled" (subtracts one extra base_cost_per_trade per period).
    """
    if cost_multiplier < 0:
        raise ValueError("cost_multiplier must be non-negative")
    extra_cost = base_cost_per_trade * (cost_multiplier - 1.0)
    return returns - extra_cost


def apply_win_rate_degradation(returns: pd.Series, flip_fraction: float, rng: np.random.Generator | None = None) -> pd.Series:
    """Stress test for alpha decay / regime change: randomly flips the sign
    of `flip_fraction` of the WINNING returns to their negative (turning some
    fraction of past wins into losses of the same magnitude) - simulating a
    strategy whose edge has partially or fully stopped working, without
    assuming any particular new win rate."""
    if not 0.0 <= flip_fraction <= 1.0:
        raise ValueError("flip_fraction must be in [0, 1]")
    if rng is None:
        rng = np.random.default_rng()

    result = returns.copy()
    win_mask = result > 0
    win_indices = result.index[win_mask]
    n_to_flip = int(round(len(win_indices) * flip_fraction))
    if n_to_flip > 0:
        flip_indices = rng.choice(win_indices, size=n_to_flip, replace=False)
        result.loc[flip_indices] = -result.loc[flip_indices]
    return result


@dataclass
class StressTestResult:
    scenario_name: str
    total_return: float
    max_drawdown: float
    sharpe: float


def run_adversarial_stress_suite(
    returns: pd.Series,
    shock_pct: float = -0.10,
    cost_multiplier: float = 2.0,
    base_cost_per_trade: float = 0.0005,
    win_degradation_fraction: float = 0.30,
    rng: np.random.Generator | None = None,
) -> list[StressTestResult]:
    """Runs a fixed suite of adversarial scenarios against `returns` and
    reports total return / max drawdown / Sharpe for the BASELINE and each
    stressed variant, so a caller can see exactly how much each stress
    degrades the strategy relative to its own unstressed history.

    Every parameter has a documented-as-engineering-design default; nothing
    here is derived from the paper's own numbers (see module docstring)."""
    if rng is None:
        rng = np.random.default_rng()

    scenarios: dict[str, pd.Series] = {
        "baseline": returns,
        "single_shock": apply_single_shock(returns, shock_pct, len(returns) // 2),
        "cost_stress": apply_cost_multiplier(returns, cost_multiplier, base_cost_per_trade),
        "win_rate_degradation": apply_win_rate_degradation(returns, win_degradation_fraction, rng),
    }

    results = []
    for name, series in scenarios.items():
        total_return = float((1.0 + series).prod() - 1.0) if len(series) > 0 else 0.0
        results.append(
            StressTestResult(
                scenario_name=name,
                total_return=total_return,
                max_drawdown=max_drawdown_from_returns(series),
                sharpe=sharpe_ratio(series),
            )
        )
    return results
