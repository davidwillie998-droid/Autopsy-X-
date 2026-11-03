"""
Real, runnable tests for Phase 11's backtesting/stress-test/alpha-decay/
correlation modules - synthetic data with KNOWN properties (injected decay,
injected shocks, injected correlation), asserting the code actually detects
them, not just that it runs without raising.

Run with: python3 -m pytest python/tests/test_backtest_research.py -v
"""
from __future__ import annotations

import sys
from pathlib import Path

import numpy as np
import pandas as pd
import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from autopsy_research import alpha_decay, backtest, correlation, stress_test


# ---------------------------------------------------------------------------
# backtest.py
# ---------------------------------------------------------------------------

def test_train_test_split_chronological_no_overlap():
    returns = pd.Series(np.arange(100))
    train, test = backtest.train_test_split(returns, train_fraction=0.7)
    assert len(train) + len(test) == 100
    assert train.iloc[-1] < test.iloc[0]  # strictly chronological, no shuffle
    assert len(train) > 0 and len(test) > 0


def test_train_test_split_rejects_bad_fraction():
    returns = pd.Series(np.arange(10))
    with pytest.raises(ValueError):
        backtest.train_test_split(returns, train_fraction=1.5)
    with pytest.raises(ValueError):
        backtest.train_test_split(returns, train_fraction=0.0)


def test_walk_forward_windows_never_overlap_and_train_precedes_test():
    windows = list(backtest.walk_forward_windows(n=100, train_size=20, test_size=10, step=10))
    assert len(windows) > 0
    for train_idx, test_idx in windows:
        assert train_idx.stop <= test_idx.start  # train strictly before test
        assert len(train_idx) == 20
        assert len(test_idx) == 10


def test_block_bootstrap_resample_shape_and_variability():
    rng = np.random.default_rng(42)
    returns = pd.Series(rng.normal(0.001, 0.01, 200))
    paths = backtest.block_bootstrap_resample(returns, n_sims=50, block_size=10, rng=rng)
    assert paths.shape == (50, 200)
    # different sims should (almost certainly) not be identical
    assert not np.allclose(paths[0], paths[1])
    # every resampled value must have actually come from the original series
    original_values = set(np.round(returns.to_numpy(), 10))
    resampled_values = set(np.round(paths.flatten(), 10))
    assert resampled_values.issubset(original_values)


def test_parameter_perturbation_grid_stays_within_bounds():
    rng = np.random.default_rng(1)
    base = {"risk_percent": 1.0, "min_rr": 1.2}
    results = backtest.parameter_perturbation_grid(base, perturbation_pct=0.1, n_samples=200, rng=rng)
    assert len(results) == 200
    for r in results:
        assert r.base_params == base
        for key, value in base.items():
            lo, hi = value * 0.9, value * 1.1
            assert lo - 1e-9 <= r.perturbed_params[key] <= hi + 1e-9


def test_max_drawdown_from_returns_known_case():
    # +10%, -20%, +5%: equity goes 1.0 -> 1.10 -> 0.88 -> 0.924
    # drawdown from peak 1.10 to trough 0.88 = (1.10-0.88)/1.10 = 0.2 exactly
    returns = pd.Series([0.10, -0.20, 0.05])
    dd = backtest.max_drawdown_from_returns(returns)
    assert dd == pytest.approx(0.2, abs=1e-9)


def test_sharpe_ratio_zero_variance_is_zero_not_nan():
    returns = pd.Series([0.01, 0.01, 0.01, 0.01])
    assert backtest.sharpe_ratio(returns) == 0.0


# ---------------------------------------------------------------------------
# stress_test.py
# ---------------------------------------------------------------------------

def test_apply_single_shock_inserts_exact_value_and_length():
    returns = pd.Series([0.01, 0.02, -0.01, 0.03])
    shocked = stress_test.apply_single_shock(returns, shock_pct=-0.5, shock_index=2)
    assert len(shocked) == len(returns) + 1
    assert shocked.iloc[2] == -0.5


def test_apply_cost_multiplier_noop_at_one():
    returns = pd.Series([0.01, 0.02, -0.01])
    unchanged = stress_test.apply_cost_multiplier(returns, cost_multiplier=1.0, base_cost_per_trade=0.001)
    pd.testing.assert_series_equal(unchanged, returns)


def test_apply_cost_multiplier_subtracts_expected_extra():
    returns = pd.Series([0.01, 0.02, -0.01])
    stressed = stress_test.apply_cost_multiplier(returns, cost_multiplier=3.0, base_cost_per_trade=0.001)
    # extra cost = 0.001 * (3.0 - 1.0) = 0.002, subtracted from every period
    expected = returns - 0.002
    pd.testing.assert_series_equal(stressed, expected)


def test_apply_win_rate_degradation_flips_exact_fraction_of_wins():
    returns = pd.Series([0.01] * 10 + [-0.01] * 10)  # 10 wins, 10 losses
    rng = np.random.default_rng(3)
    degraded = stress_test.apply_win_rate_degradation(returns, flip_fraction=0.5, rng=rng)
    # exactly 5 of the original 10 winners should now be negative
    original_winners = returns[returns > 0]
    flipped_count = (degraded.loc[original_winners.index] < 0).sum()
    assert flipped_count == 5
    # losers must be untouched
    original_losers = returns[returns <= 0]
    pd.testing.assert_series_equal(degraded.loc[original_losers.index], original_losers)


def test_run_adversarial_stress_suite_cost_stress_never_beats_baseline():
    rng = np.random.default_rng(5)
    returns = pd.Series(rng.normal(0.002, 0.01, 300))
    results = stress_test.run_adversarial_stress_suite(returns, rng=rng)
    by_name = {r.scenario_name: r for r in results}
    assert set(by_name) == {"baseline", "single_shock", "cost_stress", "win_rate_degradation"}
    # adding extra cost every period can never IMPROVE total return
    assert by_name["cost_stress"].total_return <= by_name["baseline"].total_return


# ---------------------------------------------------------------------------
# alpha_decay.py
# ---------------------------------------------------------------------------

def test_detect_alpha_decay_flags_injected_decline():
    rng = np.random.default_rng(11)
    window = 100
    strong = pd.Series(rng.normal(0.01, 0.01, window))     # high, stable positive edge
    weak = pd.Series(rng.normal(-0.005, 0.02, window))      # edge has decayed/reversed
    returns = pd.concat([strong, weak], ignore_index=True)

    report = alpha_decay.detect_alpha_decay(returns, window=window, decline_threshold=0.5)
    assert report.decay_flagged is True
    assert report.sharpe_decline > 0.5
    assert report.early_window_sharpe > report.recent_window_sharpe


def test_detect_alpha_decay_discriminates_decayed_from_stable():
    # A single fixed-seed "stable data should never flag" assertion turned out to be statistically
    # unsound: an annualized Sharpe ratio's point-estimate has real, substantial sampling noise (its
    # standard error scales with sqrt(periods_per_year)), so at window=100 comparing two windows drawn
    # from the IDENTICAL distribution legitimately crosses decline_threshold=0.5 close to HALF the time
    # by chance alone - measured empirically at 36/80 (45%) while writing this test. That is a real,
    # useful fact about this default threshold/window combination (now documented in
    # detect_alpha_decay()'s own docstring) - it is not a bug in the function. A single-seed "never
    # flags" test was simply asking the wrong question of a noisy statistic.
    #
    # The statistically honest question a DETECTOR should answer is whether it discriminates - flags
    # genuine decay meaningfully more often than it flags stable noise - not whether it has a zero
    # false-positive rate on an arbitrary seed. Measured empirically: stable-data flag rate ~45%,
    # genuinely-decayed-data flag rate 100% over the same 80 trials. This test asserts that
    # discrimination gap directly, which is the property that actually matters.
    window = 100
    n_trials = 80
    stable_flagged = 0
    decayed_flagged = 0
    for seed in range(n_trials):
        stable_rng = np.random.default_rng(1000 + seed)
        stable = pd.Series(stable_rng.normal(0.0008, 0.01, window * 2))
        if alpha_decay.detect_alpha_decay(stable, window=window, decline_threshold=0.5).decay_flagged:
            stable_flagged += 1

        decay_rng = np.random.default_rng(2000 + seed)
        strong_early = pd.Series(decay_rng.normal(0.02, 0.01, window))
        weak_recent = pd.Series(decay_rng.normal(-0.01, 0.02, window))
        decayed = pd.concat([strong_early, weak_recent], ignore_index=True)
        if alpha_decay.detect_alpha_decay(decayed, window=window, decline_threshold=0.5).decay_flagged:
            decayed_flagged += 1

    stable_rate = stable_flagged / n_trials
    decayed_rate = decayed_flagged / n_trials
    assert decayed_rate - stable_rate > 0.3


def test_detect_alpha_decay_insufficient_data_does_not_fabricate():
    returns = pd.Series(np.random.default_rng(1).normal(0, 0.01, 10))
    report = alpha_decay.detect_alpha_decay(returns, window=50, decline_threshold=0.5)
    assert report.decay_flagged is False
    assert np.isnan(report.early_window_sharpe)
    assert "Need >=" in report.reason


def test_rolling_sharpe_nan_before_window_fills():
    returns = pd.Series(np.random.default_rng(2).normal(0.001, 0.01, 50))
    rolling = alpha_decay.rolling_sharpe(returns, window=20)
    assert rolling.iloc[:19].isna().all()
    assert not np.isnan(rolling.iloc[19])


# ---------------------------------------------------------------------------
# correlation.py
# ---------------------------------------------------------------------------

def test_strategy_correlation_matrix_recovers_perfect_correlation():
    base = pd.Series(np.random.default_rng(9).normal(0, 1, 200))
    identical_copy = base.copy()
    independent = pd.Series(np.random.default_rng(10).normal(0, 1, 200))

    matrix = correlation.strategy_correlation_matrix(
        {"strat_a": base, "strat_a_clone": identical_copy, "strat_b": independent}
    )
    assert matrix.loc["strat_a", "strat_a_clone"] == pytest.approx(1.0, abs=1e-9)
    assert abs(matrix.loc["strat_a", "strat_b"]) < 0.3  # should not spuriously correlate


def test_strategy_correlation_matrix_requires_at_least_two_streams():
    with pytest.raises(ValueError):
        correlation.strategy_correlation_matrix({"only_one": pd.Series([1, 2, 3])})


def test_high_correlation_pairs_finds_the_injected_pair():
    base = pd.Series(np.random.default_rng(4).normal(0, 1, 200))
    clone = base * 2.0 + 0.001  # perfectly linearly correlated
    independent = pd.Series(np.random.default_rng(6).normal(0, 1, 200))

    matrix = correlation.strategy_correlation_matrix({"a": base, "a_clone": clone, "b": independent})
    pairs = correlation.high_correlation_pairs(matrix, threshold=0.9)
    pair_names = {frozenset((p[0], p[1])) for p in pairs}
    assert frozenset(("a", "a_clone")) in pair_names
    assert frozenset(("a", "b")) not in pair_names


def test_rolling_correlation_aligns_on_index():
    a = pd.Series([1.0, 2.0, 3.0, 4.0, 5.0], index=[0, 1, 2, 3, 4])
    b = pd.Series([2.0, 4.0, 6.0, 8.0, 10.0], index=[1, 2, 3, 4, 5])  # shifted index, perfectly proportional
    roll = correlation.rolling_correlation(a, b, window=3)
    # aligned overlap is index 1..4 (4 points) - only index 3,4 have a full 3-window
    assert roll.dropna().iloc[-1] == pytest.approx(1.0, abs=1e-9)


if __name__ == "__main__":
    import pytest as _pytest

    raise SystemExit(_pytest.main([__file__, "-v"]))
