"""Tests for the Phase 5 real-data loader (research/information_value/data_loader.py)."""
from __future__ import annotations

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[3]))

from research.information_value.data_loader import load_joint_dataset


def test_joint_dataset_loads_and_is_chronological():
    df, report = load_joint_dataset()
    assert len(df) == report.joint_rows
    assert df["date"].is_monotonic_increasing
    assert df["date"].duplicated().sum() == 0


def test_weekend_rows_are_dropped():
    df, report = load_joint_dataset()
    assert report.xau_rows_weekend_dropped == 1410
    assert (df["date"].dt.weekday < 5).all(), "no Saturday/Sunday dates should survive"


def test_eur_ohlc_consistency_preserved():
    df, report = load_joint_dataset()
    assert report.eur_rows_ohlc_inconsistent_dropped == 0
    assert (df["eur_low"] <= df["eur_open"]).all()
    assert (df["eur_open"] <= df["eur_high"]).all()
    assert (df["eur_low"] <= df["eur_close"]).all()
    assert (df["eur_close"] <= df["eur_high"]).all()


def test_log_returns_computed_correctly_and_causally():
    df, _ = load_joint_dataset()
    import numpy as np
    expected = np.log(df["xau_close"].iloc[5] / df["xau_close"].iloc[4])
    assert abs(df["xau_log_return"].iloc[5] - expected) < 1e-12
    # first row's return is NaN (no prior bar) - never fabricated as 0
    assert df["xau_log_return"].iloc[0] != df["xau_log_return"].iloc[0]  # NaN != NaN


def test_no_prices_are_non_positive():
    df, _ = load_joint_dataset()
    for col in ("xau_close", "eur_open", "eur_high", "eur_low", "eur_close"):
        assert (df[col] > 0).all()


def test_reproducible_without_network():
    """The loader must work purely from the committed raw files - no API call."""
    df1, r1 = load_joint_dataset()
    df2, r2 = load_joint_dataset()
    assert r1 == r2
    assert df1.equals(df2)
