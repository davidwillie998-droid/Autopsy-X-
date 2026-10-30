"""Backtesting framework primitives: in-sample/out-of-sample splits, walk-forward
windows, block-bootstrap Monte Carlo resampling, and parameter-perturbation grids.

ENGINEERING DESIGN, not paper-sourced. The source paper (Malhotra, SSRN 3306817)
does not specify a backtesting methodology, split ratios, or a Monte Carlo scheme -
these are standard, well-established quantitative-finance techniques (walk-forward
analysis, block bootstrap for autocorrelated returns, parameter sensitivity
analysis), implemented here as genuinely runnable, tested code rather than
described in the abstract.

This module operates on a plain 1-D returns series (e.g. a pandas Series of
per-trade or per-period P&L/returns) - it has no dependency on and is never
imported by the MQL5 codebase (see README.md, "Research vs Live Separation").
"""
from __future__ import annotations

from dataclasses import dataclass
from typing import Callable, Iterator

import numpy as np
import pandas as pd


def train_test_split(returns: pd.Series, train_fraction: float = 0.7) -> tuple[pd.Series, pd.Series]:
    """Simple chronological in-sample / out-of-sample split.

    Never shuffles - returns are a time series, and shuffling before splitting
    would leak future information into the "in-sample" set (lookahead bias).
    """
    if not 0.0 < train_fraction < 1.0:
        raise ValueError("train_fraction must be in (0, 1)")
    n = len(returns)
    split_idx = int(round(n * train_fraction))
    split_idx = max(1, min(n - 1, split_idx))  # keep both sides non-empty
    return returns.iloc[:split_idx], returns.iloc[split_idx:]


def walk_forward_windows(
    n: int, train_size: int, test_size: int, step: int | None = None
) -> Iterator[tuple[range, range]]:
    """Yields (train_indices, test_indices) for walk-forward analysis.

    Each window's train slice comes strictly before its test slice - a real
    walk-forward should never fit on data (even partially) that its
    corresponding test slice already occurred within.
    """
    if train_size <= 0 or test_size <= 0:
        raise ValueError("train_size and test_size must be positive")
    if step is None:
        step = test_size
    if step <= 0:
        raise ValueError("step must be positive")

    start = 0
    while start + train_size + test_size <= n:
        train_idx = range(start, start + train_size)
        test_idx = range(start + train_size, start + train_size + test_size)
        yield train_idx, test_idx
        start += step


def block_bootstrap_resample(
    returns: pd.Series, n_sims: int, block_size: int, rng: np.random.Generator | None = None
) -> np.ndarray:
    """Monte Carlo resampling via the (circular) block bootstrap.

    A plain iid bootstrap (resampling individual returns with replacement)
    destroys any real autocorrelation/clustering in the original series
    (e.g. volatility clustering, streaks) - the block bootstrap resamples
    contiguous BLOCKS instead, which preserves short-range dependence.
    "Circular" wraps the series so every index has an equal chance of
    starting a block, including near the end (no dead zone / block-length
    edge bias).

    Returns an (n_sims, len(returns)) array of resampled return paths -
    NOT equity curves; the caller derives equity/drawdown from these paths
    as needed (kept separate so this function has exactly one job).
    """
    if block_size <= 0:
        raise ValueError("block_size must be positive")
    n = len(returns)
    if n == 0:
        raise ValueError("returns must be non-empty")
    if rng is None:
        rng = np.random.default_rng()

    values = returns.to_numpy()
    n_blocks_needed = int(np.ceil(n / block_size))
    out = np.empty((n_sims, n), dtype=float)

    for sim in range(n_sims):
        start_indices = rng.integers(0, n, size=n_blocks_needed)
        pieces = []
        for start in start_indices:
            # circular wrap: indices past the end wrap back to the start
            idx = (np.arange(start, start + block_size)) % n
            pieces.append(values[idx])
        path = np.concatenate(pieces)[:n]
        out[sim] = path

    return out


@dataclass
class ParameterPerturbationResult:
    """One perturbed parameter set alongside the base it was derived from."""

    base_params: dict
    perturbed_params: dict
    perturbation_pct: dict  # per-key actual signed pct change applied


def parameter_perturbation_grid(
    base_params: dict[str, float],
    perturbation_pct: float,
    n_samples: int,
    rng: np.random.Generator | None = None,
) -> list[ParameterPerturbationResult]:
    """Generates `n_samples` parameter sets, each an independent uniform
    perturbation of `base_params` within +/- `perturbation_pct` (e.g. 0.10 for
    +/-10%) of each parameter's own value.

    Purpose: a strategy whose backtest results collapse under small parameter
    perturbations is a strategy that was overfit to its exact parameter
    values, not a robust edge - this is the standard "does it survive nearby
    parameters" robustness check the spec's own "parameter-perturbation"
    requirement asks for. This function only generates the parameter sets;
    it does not run a backtest itself (the caller supplies whatever backtest
    function operates on these parameters - keeps this module free of any
    assumption about what a "strategy" is).
    """
    if perturbation_pct < 0:
        raise ValueError("perturbation_pct must be non-negative")
    if n_samples <= 0:
        raise ValueError("n_samples must be positive")
    if rng is None:
        rng = np.random.default_rng()

    results = []
    for _ in range(n_samples):
        perturbed = {}
        pct_applied = {}
        for key, value in base_params.items():
            pct = rng.uniform(-perturbation_pct, perturbation_pct)
            perturbed[key] = value * (1.0 + pct)
            pct_applied[key] = pct
        results.append(ParameterPerturbationResult(dict(base_params), perturbed, pct_applied))
    return results


def max_drawdown_from_returns(returns: pd.Series) -> float:
    """Max drawdown (as a positive fraction) of the cumulative-return equity
    curve implied by `returns` (interpreted as period-over-period simple
    returns, compounded multiplicatively). Returns 0.0 for an empty series."""
    if len(returns) == 0:
        return 0.0
    equity = (1.0 + returns).cumprod()
    running_peak = equity.cummax()
    drawdown = (running_peak - equity) / running_peak
    return float(drawdown.max())


def sharpe_ratio(returns: pd.Series, periods_per_year: float = 252.0) -> float:
    """Annualized Sharpe ratio (zero risk-free rate) of a returns series.
    Returns 0.0 for fewer than 2 samples or zero variance - never a
    fabricated ratio from a degenerate sample."""
    if len(returns) < 2:
        return 0.0
    std = returns.std(ddof=1)
    if std == 0 or np.isnan(std):
        return 0.0
    return float(returns.mean() / std * np.sqrt(periods_per_year))
