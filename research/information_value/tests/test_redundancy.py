"""Tests for redundancy.py."""
from __future__ import annotations

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[3]))

import numpy as np
import pandas as pd

from research.information_value.redundancy import classify_redundancy, pairwise_redundancy


def test_classify_redundancy_thresholds():
    assert classify_redundancy(0.0) == "LOW REDUNDANCY"
    assert classify_redundancy(0.29) == "LOW REDUNDANCY"
    assert classify_redundancy(0.3) == "MODERATE REDUNDANCY"
    assert classify_redundancy(0.69) == "MODERATE REDUNDANCY"
    assert classify_redundancy(0.7) == "HIGH REDUNDANCY"
    assert classify_redundancy(1.0) == "HIGH REDUNDANCY"


def test_identical_features_are_high_redundancy():
    rng = np.random.default_rng(1)
    x = rng.normal(0, 1, 200)
    df = pd.DataFrame({
        "xau_log_return": x, "return_autocorr": x, "directional_persist": rng.normal(0, 1, 200),
        "reversal_frequency": rng.normal(0, 1, 200), "transmission_assoc_signed": rng.normal(0, 1, 200),
        "transmission_confidence": rng.normal(0, 1, 200),
    })
    result = pairwise_redundancy(df)
    row = result[(result["feature_a"] == "xau_log_return") & (result["feature_b"] == "return_autocorr")].iloc[0]
    assert row["classification"] == "HIGH REDUNDANCY"
    assert abs(row["pearson_corr"] - 1.0) < 1e-9


def test_independent_features_are_low_redundancy():
    rng = np.random.default_rng(2)
    df = pd.DataFrame({c: rng.normal(0, 1, 2000) for c in
                        ["xau_log_return", "return_autocorr", "directional_persist",
                         "reversal_frequency", "transmission_assoc_signed", "transmission_confidence"]})
    result = pairwise_redundancy(df)
    assert (result["classification"] == "LOW REDUNDANCY").all()


def test_all_pairs_covered_no_self_pairs():
    rng = np.random.default_rng(3)
    df = pd.DataFrame({c: rng.normal(0, 1, 100) for c in
                        ["xau_log_return", "return_autocorr", "directional_persist",
                         "reversal_frequency", "transmission_assoc_signed", "transmission_confidence"]})
    result = pairwise_redundancy(df)
    assert len(result) == 15  # C(6,2)
    assert (result["feature_a"] != result["feature_b"]).all()
