"""Phase 5 unit-of-analysis / feature construction (real data).

Builds, for each row t of the real joint XAU/EUR frame
(data_loader.load_joint_dataset()), ONLY the features that scope.py's audit
established are faithfully reconstructible from close-only XAU + OHLC
EUR/USD data - read scope.py before touching this file.

Every feature at row t uses only data at or before t (rolling windows are
causal by construction: pandas .rolling()/a manual trailing-window loop
both stop at the current index, never look ahead). This is verified
directly by test_feature_construction.py's own future-injection test, not
merely assumed.

FEATURES BUILT HERE:
  1. raw_log_return       - XAU's own log return at t (Market State,
                             reduced to what's reconstructible - scope.py §2)
  2. return_autocorr       -\\
  3. directional_persist    | THE SAME formulas as
  4. reversal_frequency    -/ VolatilitySerialityEngine.mqh's own genuinely-
                             new return-serial-dependence computation
                             (lag-1 autocorrelation, % dominant-sign bars,
                             % sign-flipping transitions), reimplemented
                             here in Python over a trailing window of
                             REAL XAU log returns - not a reinvention, the
                             identical algorithm.
  5. transmission_state    -\\
  6. transmission_assoc     | lead_lag.py's own compute_snapshot(), called
  7. transmission_dir       | DIRECTLY (imported, not reimplemented) on a
  8. transmission_conf     -/ trailing window of aligned XAU/EUR log
                             returns - the actual Phase 4A reference logic.

NOT built here (scope.py §2): anything needing true range/ATR (Regime's
classification, CVolatilityEngine's state taxonomy, Shock DNA).
"""
from __future__ import annotations

import sys
from pathlib import Path

import numpy as np
import pandas as pd

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "python"))
from autopsy_research.lead_lag import compute_snapshot  # noqa: E402

# Mirrors VolatilitySerialityEngine.mqh's own defaults (m_lookbackBars=50, m_minSampleSize=10)
SERIALITY_LOOKBACK = 50
SERIALITY_MIN_SAMPLE = 10

# InformationTransmissionEngine.mqh defaults m_capacity=500/m_maxLag=10/m_minSampleSize=30;
# 250 trading days (~1yr) is used here instead of 500 as a deliberate, documented compute-
# and-relevance choice for DAILY (not the engine's usual intraday) granularity - not tuned
# to produce a particular result, chosen before any transmission result was computed.
TRANSMISSION_WINDOW = 250
TRANSMISSION_MAX_LAG = 10
TRANSMISSION_MIN_SAMPLE = 30


def _return_serial_metrics_window(window: np.ndarray) -> tuple[float, float, float, int]:
    """Exact port of VolatilitySerialityEngine.mqh::Sample()'s own return-serial-
    dependence math (lines computing returnAutocorrelation/directionalPersistence/
    reversalFrequencyPct), operating on a plain 1-D array of log returns, oldest
    first. Returns (autocorr, directional_persistence_pct, reversal_freq_pct, n)."""
    n = len(window)
    if n < 2:
        return 0.0, 0.0, 0.0, n

    mean = window.mean()
    dev = window - mean
    den = float(np.sum(dev * dev))
    num = float(np.sum(dev[1:] * dev[:-1]))
    autocorr = np.clip(num / den, -1.0, 1.0) if den > 0 else 0.0

    pos = int(np.sum(window > 0))
    neg = int(np.sum(window < 0))
    non_zero = pos + neg
    dominant = max(pos, neg)
    persistence = 100.0 * dominant / non_zero if non_zero > 0 else 0.0

    signs = np.sign(window)
    transitions = 0
    flips = 0
    last_sign = 0
    for s in signs:
        if s == 0:
            continue
        if last_sign != 0:
            transitions += 1
            if s != last_sign:
                flips += 1
        last_sign = int(s)
    reversal_freq = 100.0 * flips / transitions if transitions > 0 else 0.0

    return float(autocorr), float(persistence), float(reversal_freq), n


def add_return_serial_features(df: pd.DataFrame, return_col: str = "xau_log_return",
                                lookback: int = SERIALITY_LOOKBACK,
                                min_sample: int = SERIALITY_MIN_SAMPLE) -> pd.DataFrame:
    """Adds return_autocorr / directional_persist / reversal_frequency / serial_sample_n.
    NaN (not 0.0) whenever fewer than `min_sample` non-null returns are available in the
    trailing window - "not enough evidence" is never silently reported as "measured zero"
    (the exact AVAILABLE-vs-UNAVAILABLE distinction the Phase 4B report's own fixes
    established must be preserved throughout this phase)."""
    out = df.copy()
    returns = out[return_col].to_numpy()
    n = len(returns)
    autocorr = np.full(n, np.nan)
    persist = np.full(n, np.nan)
    reversal = np.full(n, np.nan)
    sample_n = np.zeros(n, dtype=int)

    for i in range(n):
        lo = max(0, i - lookback + 1)
        window = returns[lo:i + 1]
        window = window[~np.isnan(window)]
        sample_n[i] = len(window)
        if len(window) < min_sample:
            continue
        a, p, r, _ = _return_serial_metrics_window(window)
        autocorr[i] = a
        persist[i] = p
        reversal[i] = r

    out["return_autocorr"] = autocorr
    out["directional_persist"] = persist
    out["reversal_frequency"] = reversal
    out["serial_sample_n"] = sample_n
    return out


def add_transmission_features(df: pd.DataFrame, leader_col: str = "eur_log_return",
                               receiver_col: str = "xau_log_return",
                               window: int = TRANSMISSION_WINDOW,
                               max_lag: int = TRANSMISSION_MAX_LAG,
                               min_sample_size: int = TRANSMISSION_MIN_SAMPLE) -> pd.DataFrame:
    """Adds transmission_state / transmission_assoc / transmission_direction /
    transmission_confidence by calling lead_lag.py's own compute_snapshot() on a
    trailing window of real (leader=EUR, receiver=XAU) aligned log returns ending
    at row t. EUR is the leader by convention here (arbitrary choice for a
    two-way exploratory scan - both directions are tested separately in the
    redundancy/transmission-conditionality stage, not assumed a priori)."""
    out = df.copy()
    leader = out[leader_col].to_numpy()
    receiver = out[receiver_col].to_numpy()
    n = len(out)

    states = [None] * n
    assoc = np.full(n, np.nan)
    direction = np.zeros(n, dtype=int)
    confidence = np.full(n, np.nan)

    for i in range(n):
        lo = max(0, i - window + 1)
        l_win = leader[lo:i + 1]
        r_win = receiver[lo:i + 1]
        mask = ~(np.isnan(l_win) | np.isnan(r_win))
        l_win = l_win[mask]
        r_win = r_win[mask]
        if len(l_win) < min_sample_size:
            continue
        snap = compute_snapshot(l_win, r_win, max_lag=max_lag, min_sample_size=min_sample_size)
        states[i] = snap.state.value
        assoc[i] = snap.association_strength
        direction[i] = snap.direction
        confidence[i] = snap.confidence

    out["transmission_state"] = states
    out["transmission_assoc"] = assoc
    out["transmission_direction"] = direction
    out["transmission_confidence"] = confidence
    return out


def build_feature_frame(df: pd.DataFrame) -> pd.DataFrame:
    """One call: raw return (already in df as xau_log_return) + return-serial
    features + transmission features, using only what scope.py established is
    faithfully reconstructible from this real dataset."""
    out = add_return_serial_features(df)
    out = add_transmission_features(out)
    return out
