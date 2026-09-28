"""Tests for research/information_value/targets.py: horizon math, causality,
and the mandatory no-lookahead (future-injection) property."""
from __future__ import annotations

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[3]))

import numpy as np
import pandas as pd

from research.information_value.targets import (
    HORIZONS,
    REALIZED_VOL_LOOKBACK,
    add_forward_targets,
    add_realized_vol,
    build_research_frame,
)


def _toy_frame(n=60, seed=1):
    rng = np.random.default_rng(seed)
    price = 100 * np.exp(np.cumsum(rng.normal(0, 0.01, size=n)))
    returns = np.concatenate([[np.nan], np.diff(np.log(price))])
    return pd.DataFrame({"date": pd.date_range("2020-01-01", periods=n, freq="D"),
                          "xau_close": price, "xau_log_return": returns})


def test_horizons_are_exactly_the_pre_registered_set():
    assert HORIZONS == {"H1": 1, "H2": 5, "H3": 20}


def test_realized_vol_requires_full_lookback_before_producing_a_value():
    df = _toy_frame()
    out = add_realized_vol(df, "xau_log_return")
    assert out["realized_vol"].iloc[:REALIZED_VOL_LOOKBACK].isna().all()
    assert out["realized_vol"].iloc[REALIZED_VOL_LOOKBACK:].notna().all()


def test_forward_return_matches_direct_log_price_difference():
    df = _toy_frame()
    out = build_research_frame(df)
    i = 25
    expected = np.log(df["xau_close"].iloc[i + 5] / df["xau_close"].iloc[i])
    assert abs(out["fwd_ret_H2"].iloc[i] - expected) < 1e-12


def test_final_rows_have_nan_forward_targets_not_fabricated_values():
    df = _toy_frame(n=30)
    out = build_research_frame(df)
    # last 20 rows can't have a valid H3 forward target
    assert out["fwd_ret_H3"].iloc[-20:].isna().all()


def test_no_lookahead_future_injection():
    """The mandatory future-injection test (§14/§28): the feature-side column
    (realized_vol) at row t must be identical whether or not rows AFTER t exist."""
    df_short = _toy_frame(n=40)
    df_long = _toy_frame(n=40)  # same seed -> identical first 40 rows
    extra = _toy_frame(n=60, seed=2).iloc[40:].copy()
    # graft extra future rows onto a copy sharing the identical first 40
    df_extended = pd.concat([df_long, extra], ignore_index=True)

    out_short = add_realized_vol(df_short, "xau_log_return")
    out_extended = add_realized_vol(df_extended, "xau_log_return")

    shared = min(len(out_short), 40)
    pd.testing.assert_series_equal(
        out_short["realized_vol"].iloc[:shared].reset_index(drop=True),
        out_extended["realized_vol"].iloc[:shared].reset_index(drop=True),
        check_names=False,
    )


def test_normalized_target_divides_by_causal_vol_only():
    df = _toy_frame()
    out = build_research_frame(df)
    i = 30
    expected = out["fwd_ret_H1"].iloc[i] / out["realized_vol"].iloc[i]
    assert abs(out["fwd_ret_norm_H1"].iloc[i] - expected) < 1e-12
