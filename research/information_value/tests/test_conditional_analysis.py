"""Tests for conditional_analysis.py: volatility-tercile splitting and
conditional IC reporting."""
from __future__ import annotations

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[3]))

import numpy as np
import pandas as pd

from research.information_value.conditional_analysis import add_volatility_terciles, conditional_ic


def _toy_frame(n=300, seed=1):
    rng = np.random.default_rng(seed)
    return pd.DataFrame({
        "realized_vol": rng.uniform(0.5, 3.0, n),
        "feature": rng.normal(0, 1, n),
        "target": rng.normal(0, 1, n),
    })


def test_terciles_are_roughly_equal_sized():
    df = _toy_frame(n=300)
    out = add_volatility_terciles(df)
    counts = out["vol_tercile"].value_counts()
    for tercile in ("LOW", "MID", "HIGH"):
        assert 90 <= counts[tercile] <= 110


def test_terciles_are_ordered_by_realized_vol():
    df = _toy_frame(n=300)
    out = add_volatility_terciles(df)
    means = out.groupby("vol_tercile", observed=True)["realized_vol"].mean()
    assert means["LOW"] < means["MID"] < means["HIGH"]


def test_small_frame_produces_na_terciles_not_fabricated_buckets():
    df = _toy_frame(n=10)  # below the 30-observation floor
    out = add_volatility_terciles(df)
    assert out["vol_tercile"].isna().all()


def test_conditional_ic_reports_global_plus_three_buckets():
    df = _toy_frame(n=400)
    df = add_volatility_terciles(df)
    result = conditional_ic(df, "feature", "target", block_size=2, n_permutations=200)
    assert set(result["bucket"]) == {"GLOBAL", "LOW", "MID", "HIGH"}
    assert (result["n"] > 0).all()


def test_conditional_ic_flags_small_buckets_not_silently_merged():
    rng = np.random.default_rng(2)
    df = pd.DataFrame({
        "vol_tercile": ["LOW"] * 100 + ["MID"] * 5 + ["HIGH"] * 100,
        "feature": rng.normal(0, 1, 205),
        "target": rng.normal(0, 1, 205),
    })
    result = conditional_ic(df, "feature", "target", block_size=2, n_permutations=100)
    mid_row = result[result["bucket"] == "MID"].iloc[0]
    assert mid_row["n"] == 5
    assert mid_row["small_sample_warning"] == True  # noqa: E712 - kept as a value, never dropped
