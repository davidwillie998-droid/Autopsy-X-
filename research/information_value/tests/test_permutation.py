"""Tests for permutation.py: block-permutation correctness, and the specific
overlapping-window-inflation regression this module exists to catch."""
from __future__ import annotations

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[3]))

import numpy as np
import pandas as pd

from research.information_value.permutation import block_permutation_test


def test_genuine_signal_survives_block_permutation():
    """A REAL, strong relationship (even with autocorrelated/overlapping-style
    target construction) should still show a small empirical p-value - block
    permutation must not be so conservative it can never detect anything."""
    rng = np.random.default_rng(1)
    n = 500
    pred = rng.normal(0, 1, n)
    target = 2.0 * pred + rng.normal(0, 0.3, n)  # strong genuine linear relationship
    result = block_permutation_test(pred, target, block_size=5, n_permutations=500, seed=1)
    assert result.empirical_p_value < 0.01


def test_pure_noise_does_not_reliably_survive_block_permutation():
    rng = np.random.default_rng(2)
    n = 500
    pred = rng.normal(0, 1, n)
    target = rng.normal(0, 1, n)  # genuinely unrelated
    result = block_permutation_test(pred, target, block_size=21, n_permutations=1000, seed=2)
    assert result.empirical_p_value > 0.05


def test_overlapping_window_target_inflates_naive_p_but_not_block_permutation_p():
    """Regression for the exact defect found on real data (docs/
    PHASE5_INFORMATION_VALUE_REPORT.md): a model prediction built from
    ROLLING/SMOOTHED features (autocorrelated, like ablation.py's own
    predictions - not IID) compared against a target built from 20-day
    OVERLAPPING forward sums (autocorrelated, like targets.py's own H3
    construction) - with NO real relationship between the two generating
    processes. Both series' own serial dependence combined can make a purely
    spurious relationship look highly significant under scipy's IID-assuming
    parametric p-value; block permutation (block_size >= horizon+1) must not
    be fooled the same way. This exact pattern (naive p far smaller than the
    block-permutation empirical p) is what was found on the real
    C_transmission/H3/OOS ablation cell: naive p=2.4e-6, block-permutation
    empirical p=0.15."""
    from scipy import stats

    rng = np.random.default_rng(3)
    n = 800
    horizon = 20

    # target: 20-day overlapping forward sum of IID noise (autocorrelated by construction)
    raw_returns_a = rng.normal(0, 1, n + horizon)
    overlapping_target = np.array([raw_returns_a[i:i + horizon].sum() for i in range(n)])

    # pred: a rolling mean of a SEPARATE, independent IID noise series (autocorrelated,
    # mirroring how ablation.py's own predictions are built from rolling engine features)
    raw_returns_b = rng.normal(0, 1, n + horizon)
    pred = pd.Series(raw_returns_b).rolling(window=20, min_periods=1).mean().to_numpy()[:n]

    naive = stats.spearmanr(pred, overlapping_target)
    block_result = block_permutation_test(pred, overlapping_target, block_size=horizon + 1,
                                            n_permutations=1000, seed=3)

    # the core regression property: the naive p-value is not a reliable substitute for the
    # block-permutation empirical p-value once both series carry real serial dependence -
    # naive significance claims from raw ablation output must never be trusted on their own.
    assert block_result.empirical_p_value > naive.pvalue * 10, (
        f"expected block-permutation p ({block_result.empirical_p_value}) to be "
        f"substantially less optimistic than the naive parametric p ({naive.pvalue})"
    )
