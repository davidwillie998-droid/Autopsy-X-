"""Alpha decay detection and strategy correlation/crowding proxies.

ENGINEERING DESIGN, not paper-sourced. The paper discusses that a strategy's
edge and liquidity conditions change over time and that funds must monitor
capacity/crowding (its "400 strategies" review and "third dimension of
liquidity" discussion) - it does not define "alpha decay" or a detection
formula, and does not provide real cross-fund crowding data (no retail or
even most institutional feeds expose that - see CapacityCrowdingEngine.mqh's
identical honesty caveat on the MQL5 side). Both are engineering constructs
here, built only from data actually available: this strategy's own returns
history, or return streams the caller explicitly supplies.

CRITICAL STATISTICAL RULE (spec's own instruction, carried into this
module): a decay signal is a prompt to investigate, never something to
silently re-optimize a strategy against - see detect_alpha_decay()'s own
docstring.
"""
from __future__ import annotations

from dataclasses import dataclass

import numpy as np
import pandas as pd


def rolling_sharpe(returns: pd.Series, window: int, periods_per_year: float = 252.0) -> pd.Series:
    """Rolling annualized Sharpe ratio over a trailing `window`-length
    window. NaN for any window with fewer than 2 real (non-NaN) observations
    or zero variance - never a fabricated ratio from a degenerate window."""
    if window < 2:
        raise ValueError("window must be >= 2")

    def _sharpe(x: np.ndarray) -> float:
        std = np.nanstd(x, ddof=1)
        if std == 0 or np.isnan(std):
            return np.nan
        return float(np.nanmean(x) / std * np.sqrt(periods_per_year))

    return returns.rolling(window=window, min_periods=window).apply(_sharpe, raw=True)


@dataclass
class AlphaDecayReport:
    early_window_sharpe: float
    recent_window_sharpe: float
    sharpe_decline: float          # early - recent (positive = declining)
    decay_flagged: bool
    reason: str


def detect_alpha_decay(
    returns: pd.Series,
    window: int,
    decline_threshold: float,
    periods_per_year: float = 252.0,
) -> AlphaDecayReport:
    """Compares the Sharpe ratio of the EARLIEST `window`-length slice of
    `returns` against the MOST RECENT `window`-length slice. Flags decay when
    the recent Sharpe is at least `decline_threshold` LOWER than the early
    Sharpe (e.g. decline_threshold=0.5 flags any 0.5+ drop in annualized
    Sharpe).

    This is a coarse, two-point comparison by design (not a trend-line fit
    over the whole series) - it answers one specific, honest question ("does
    the most recent stretch look meaningfully worse than the earliest
    stretch this strategy has data for"), not a general trend test that
    could be fooled by a single good/bad early or recent window. A caller
    wanting a smoother trend read should use rolling_sharpe() directly and
    apply their own trend statistic.

    NEVER auto-act on this alone (spec's own "critical statistical rule",
    carried into this module): a flagged decay is a signal to investigate
    further (more data, regime context, out-of-sample validation), not a
    standalone instruction to shut down or re-tune a strategy - see
    README.md and Statistics.mqh's own EvaluateGate() for the equivalent
    "insufficient data / don't over-trust a single reading" discipline this
    codebase applies everywhere.

    A KNOWN, TESTED STATISTICAL PROPERTY worth knowing before choosing
    `decline_threshold`: an annualized Sharpe ratio's point estimate has
    substantial sampling noise (its standard error scales with
    sqrt(periods_per_year)), so even TWO WINDOWS DRAWN FROM THE IDENTICAL
    DISTRIBUTION can legitimately show a swing of several tenths of a point
    by chance alone - a threshold around 0.5 can false-positive on genuinely
    stable data something like 15-30% of the time at window sizes in the
    hundreds (confirmed empirically in this package's own test suite -
    see test_backtest_research.py's
    test_detect_alpha_decay_false_positive_rate_is_low_on_stable_edge). A
    real decay signal should therefore be corroborated with more evidence
    (a much larger decline, a longer window, or agreement with
    rolling_sharpe()'s own trend) before being treated as more than a
    prompt to look closer - this is the same reasoning as the "never
    auto-act on this alone" rule above, made concrete with a number.
    """
    if window < 2:
        raise ValueError("window must be >= 2")
    if len(returns) < 2 * window:
        return AlphaDecayReport(
            early_window_sharpe=float("nan"),
            recent_window_sharpe=float("nan"),
            sharpe_decline=float("nan"),
            decay_flagged=False,
            reason=f"Need >= {2 * window} observations for two non-overlapping windows (have {len(returns)})",
        )

    early = returns.iloc[:window]
    recent = returns.iloc[-window:]

    def _sharpe(s: pd.Series) -> float:
        std = s.std(ddof=1)
        if std == 0 or np.isnan(std):
            return float("nan")
        return float(s.mean() / std * np.sqrt(periods_per_year))

    early_sharpe = _sharpe(early)
    recent_sharpe = _sharpe(recent)

    if np.isnan(early_sharpe) or np.isnan(recent_sharpe):
        return AlphaDecayReport(
            early_window_sharpe=early_sharpe,
            recent_window_sharpe=recent_sharpe,
            sharpe_decline=float("nan"),
            decay_flagged=False,
            reason="Zero variance in an early or recent window - Sharpe undefined",
        )

    decline = early_sharpe - recent_sharpe
    flagged = decline >= decline_threshold
    reason = (
        f"recent Sharpe {recent_sharpe:.3f} vs early Sharpe {early_sharpe:.3f} "
        f"(decline {decline:.3f}, threshold {decline_threshold:.3f})"
    )
    return AlphaDecayReport(early_sharpe, recent_sharpe, decline, flagged, reason)
