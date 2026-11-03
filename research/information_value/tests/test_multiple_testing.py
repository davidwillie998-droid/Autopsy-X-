"""Tests for multiple_testing.py's Benjamini-Hochberg implementation,
verified against a hand-worked example and standard properties."""
from __future__ import annotations

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[3]))

import numpy as np

from research.information_value.multiple_testing import benjamini_hochberg


def test_hand_worked_example():
    """Classic textbook example: p = [0.01, 0.02, 0.03, 0.04, 0.20], n=5, alpha=0.05.
    BH critical values: i/n*alpha = [0.01, 0.02, 0.03, 0.04, 0.05].
    p_(i) <= critical for i=1..4 (0.04<=0.04), fails at i=5 (0.20>0.05).
    Largest i satisfying p_(i)<=critical is i=4 -> reject the first 4."""
    p = [0.01, 0.02, 0.03, 0.04, 0.20]
    result = benjamini_hochberg(p, alpha=0.05)
    assert result.n_rejected == 4
    assert list(result.rejected) == [True, True, True, True, False]


def test_all_null_rarely_rejects_much():
    rng = np.random.default_rng(0)
    # uniform p-values under a true null - BH should control FDR near alpha on average
    p = rng.uniform(0, 1, size=200).tolist()
    result = benjamini_hochberg(p, alpha=0.05)
    # not a tight bound (stochastic), but should be a small minority, not most of them
    assert result.n_rejected < 30


def test_all_significant_rejects_all():
    p = [1e-10] * 10
    result = benjamini_hochberg(p, alpha=0.05)
    assert result.n_rejected == 10
    assert all(result.rejected)


def test_nan_p_value_counts_against_significance():
    p = [0.001, 0.001, float("nan")]
    result = benjamini_hochberg(p, alpha=0.05)
    assert result.rejected[2] is False
    assert result.q_values[2] == 1.0


def test_q_values_are_monotonic_with_sorted_p():
    rng = np.random.default_rng(5)
    p = rng.uniform(0, 1, size=50).tolist()
    result = benjamini_hochberg(p)
    order = np.argsort(p)
    q_sorted = np.array(result.q_values)[order]
    assert np.all(np.diff(q_sorted) >= -1e-12)  # non-decreasing along sorted p


def test_empty_input():
    result = benjamini_hochberg([])
    assert result.n_tests == 0
    assert result.n_rejected == 0
