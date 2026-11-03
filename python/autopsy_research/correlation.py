"""Strategy correlation / crowding proxy across multiple return streams.

ENGINEERING DESIGN, not paper-sourced - see alpha_decay.py's module
docstring for the same honesty caveat: this package has no access to real
cross-fund positioning data, so "crowding" here can only ever mean
CORRELATION AMONG RETURN STREAMS THE CALLER SUPPLIES (this strategy across
different symbols/parameter sets, or against any benchmark series a
researcher chooses to pass in) - never a measurement of other market
participants.
"""
from __future__ import annotations

import numpy as np
import pandas as pd


def strategy_correlation_matrix(returns_by_name: dict[str, pd.Series]) -> pd.DataFrame:
    """Pairwise Pearson correlation matrix across named return streams.

    Series are aligned on their index (e.g. timestamp) via an inner join
    before computing correlation - streams with no overlapping observations
    correlate as NaN rather than a fabricated 0.0, since "uncorrelated" and
    "never observed together" are genuinely different things.
    """
    if len(returns_by_name) < 2:
        raise ValueError("Need at least 2 return streams to compute a correlation matrix")
    frame = pd.DataFrame(returns_by_name)
    return frame.corr(method="pearson")


def rolling_correlation(a: pd.Series, b: pd.Series, window: int) -> pd.Series:
    """Rolling Pearson correlation between two return streams over a
    trailing `window`. Aligned on shared index first (see
    strategy_correlation_matrix's own note on NaN-vs-zero)."""
    if window < 2:
        raise ValueError("window must be >= 2")
    aligned_a, aligned_b = a.align(b, join="inner")
    return aligned_a.rolling(window=window, min_periods=window).corr(aligned_b)


def high_correlation_pairs(corr_matrix: pd.DataFrame, threshold: float) -> list[tuple[str, str, float]]:
    """Extracts every distinct pair (i != j, each pair reported once) whose
    ABSOLUTE correlation is >= `threshold` - the crowding-proxy signal
    itself: a set of strategies/symbols whose returns move together above
    the threshold may be effectively the same bet taken multiple times,
    understating true portfolio risk if treated as diversified.
    """
    if not 0.0 <= threshold <= 1.0:
        raise ValueError("threshold must be in [0, 1]")
    names = list(corr_matrix.columns)
    pairs = []
    for i in range(len(names)):
        for j in range(i + 1, len(names)):
            value = corr_matrix.iloc[i, j]
            if pd.isna(value):
                continue
            if abs(value) >= threshold:
                pairs.append((names[i], names[j], float(value)))
    return pairs
