"""Tests for feature_construction.py: formula correctness against a hand-
computed example, availability semantics, and the mandatory no-lookahead
(future-injection) property."""
from __future__ import annotations

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[3]))

import numpy as np
import pandas as pd

from research.information_value.feature_construction import (
    SERIALITY_MIN_SAMPLE,
    _return_serial_metrics_window,
    add_return_serial_features,
    add_transmission_features,
    build_feature_frame,
)


def test_return_serial_metrics_hand_computed_example():
    """Hand-computed against VolatilitySerialityEngine.mqh's own formula:
    window = [1, -1, 1, -1, 1] (alternating sign, unit magnitude).
    mean = 0.2; deviations = [0.8,-1.2,0.8,-1.2,0.8]
    den = sum(dev^2) = 0.64+1.44+0.64+1.44+0.64 = 4.8
    num = sum(dev[i]*dev[i-1] for i=1..4) = (-1.2*0.8)+(0.8*-1.2)+(-1.2*0.8)+(0.8*-1.2)
        = -0.96-0.96-0.96-0.96 = -3.84
    autocorr = -3.84/4.8 = -0.8
    persistence: pos=3, neg=2, nonzero=5, dominant=3 -> 60.0
    reversal: every consecutive pair flips sign -> transitions=4, flips=4 -> 100.0
    """
    window = np.array([1.0, -1.0, 1.0, -1.0, 1.0])
    autocorr, persist, reversal, n = _return_serial_metrics_window(window)
    assert abs(autocorr - (-0.8)) < 1e-9
    assert abs(persist - 60.0) < 1e-9
    assert abs(reversal - 100.0) < 1e-9
    assert n == 5


def test_return_serial_metrics_zero_variance_window():
    window = np.zeros(10)
    autocorr, persist, reversal, n = _return_serial_metrics_window(window)
    assert autocorr == 0.0  # den==0 -> 0.0, never a fabricated/NaN value
    assert persist == 0.0   # no nonzero returns -> 0.0, not undefined
    assert reversal == 0.0


def _toy_returns_frame(n=120, seed=7):
    rng = np.random.default_rng(seed)
    r = rng.normal(0, 0.01, size=n)
    r[0] = np.nan
    dates = pd.date_range("2020-01-01", periods=n, freq="D")
    eur = rng.normal(0, 0.01, size=n)
    eur[0] = np.nan
    return pd.DataFrame({"date": dates, "xau_log_return": r, "eur_log_return": eur})


def test_insufficient_sample_is_nan_not_zero():
    df = _toy_returns_frame(n=SERIALITY_MIN_SAMPLE - 1 + 1)  # exactly at the edge
    out = add_return_serial_features(df)
    # first row after warmup has < min_sample non-null returns -> NaN, never fabricated 0.0
    assert out["return_autocorr"].iloc[:SERIALITY_MIN_SAMPLE - 2].isna().all()


def test_serial_features_no_lookahead():
    """Future-injection test: identical shared prefix -> identical feature values
    at every shared index, regardless of what rows are appended afterward."""
    df_short = _toy_returns_frame(n=80, seed=3)
    df_long_prefix = _toy_returns_frame(n=80, seed=3)  # identical first 80 rows
    extra = _toy_returns_frame(n=40, seed=99)
    df_long = pd.concat([df_long_prefix, extra], ignore_index=True)

    out_short = add_return_serial_features(df_short)
    out_long = add_return_serial_features(df_long)

    for col in ("return_autocorr", "directional_persist", "reversal_frequency"):
        a = out_short[col].iloc[:80].to_numpy()
        b = out_long[col].iloc[:80].to_numpy()
        np.testing.assert_array_equal(a, b, err_msg=f"lookahead leakage detected in {col}")


def test_transmission_features_no_lookahead():
    df_short = _toy_returns_frame(n=60, seed=11)
    df_long_prefix = _toy_returns_frame(n=60, seed=11)
    extra = _toy_returns_frame(n=30, seed=55)
    df_long = pd.concat([df_long_prefix, extra], ignore_index=True)

    out_short = add_transmission_features(df_short, window=40, min_sample_size=30)
    out_long = add_transmission_features(df_long, window=40, min_sample_size=30)

    a = out_short["transmission_assoc"].iloc[:60].to_numpy()
    b = out_long["transmission_assoc"].iloc[:60].to_numpy()
    np.testing.assert_allclose(a, b, equal_nan=True, err_msg="lookahead leakage in transmission_assoc")

    a_dir = out_short["transmission_direction"].iloc[:60].to_numpy()
    b_dir = out_long["transmission_direction"].iloc[:60].to_numpy()
    np.testing.assert_array_equal(a_dir, b_dir)


def test_transmission_state_is_none_not_fabricated_below_min_sample():
    df = _toy_returns_frame(n=10)
    out = add_transmission_features(df, window=40, min_sample_size=30)
    assert out["transmission_state"].isna().all() or (out["transmission_state"] == None).all()  # noqa: E711


def test_build_feature_frame_runs_end_to_end_on_toy_data():
    df = _toy_returns_frame(n=150, seed=5)
    out = build_feature_frame(df)
    expected_cols = {"return_autocorr", "directional_persist", "reversal_frequency",
                      "serial_sample_n", "transmission_state", "transmission_assoc",
                      "transmission_direction", "transmission_confidence"}
    assert expected_cols.issubset(out.columns)
    assert len(out) == 150
