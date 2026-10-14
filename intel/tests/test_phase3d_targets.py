from __future__ import annotations

import pytest

from autopsyx.research.phase3d_targets import (
    CANDIDATE_HORIZONS_MS,
    CANDIDATE_UPSIDE_THRESHOLDS,
    OUTCOMES,
    PriceBar,
    TargetSpec,
    build_target_labels,
    intervals_overlap,
    purge_overlapping_training_indices,
)


def bars(prices, *, liquidity=100_000.0):
    """Create one-minute OHLC bars from (open, high, low, close) tuples."""
    return [
        PriceBar(i * 60_000, *ohlc, liquidity)
        for i, ohlc in enumerate(prices)
    ]


def spec(**overrides):
    values = dict(
        horizon_ms=3 * 60_000,
        upside_threshold_pct=0.05,
        downside_threshold_pct=0.05,
        latency_ms=60_000,
        fee_bps=10,
        slippage_bps=10,
        max_participation_pct=0.10,
        min_liquidity_usd=1_000,
    )
    values.update(overrides)
    return TargetSpec(**values)


def test_contract_candidate_grid_is_explicit_and_separate_from_frozen_phase3b():
    assert CANDIDATE_HORIZONS_MS == (300_000, 900_000, 3_600_000)
    assert CANDIDATE_UPSIDE_THRESHOLDS == (0.05, 0.10, 0.20)


def test_labels_upside_first_after_execution_latency_and_costs():
    data = bars([
        (100, 101, 99, 100),
        (100, 108, 99, 106),
        (106, 108, 104, 107),
        (107, 109, 105, 108),
    ])
    label = build_target_labels(data, token_key="solana:mint", pool_key="pool-a",
                                entry_notional_usd=100, spec=spec())[0]
    assert label.entry_ts_ms == 60_000
    assert label.outcome == "UPSIDE_FIRST"
    assert label.realized_net_return_pct is not None
    assert label.realized_net_return_pct > 5
    assert label.contract_version == "1.0.0"


def test_mfe_mae_stop_at_first_barrier_instead_of_using_later_future_prices():
    data = bars([
        (100, 101, 99, 100),
        (100, 101, 99, 100),
        (100, 108, 99, 106),
        (106, 110, 50, 60),
    ])
    label = build_target_labels(data, token_key="solana:mint", pool_key="pool-a",
                                entry_notional_usd=100, spec=spec())[0]
    assert label.outcome == "UPSIDE_FIRST"
    assert label.observed_mae_net_pct is not None
    assert label.observed_mae_net_pct > -5


def test_downside_first_is_not_a_momentum_success():
    data = bars([
        (100, 101, 99, 100),
        (100, 101, 90, 92),
        (92, 94, 89, 90),
        (90, 92, 88, 91),
    ])
    label = build_target_labels(data, token_key="solana:mint", pool_key="pool-a",
                                entry_notional_usd=100, spec=spec())[0]
    assert label.outcome == "DOWNSIDE_FIRST"
    assert label.realized_net_return_pct is not None
    assert label.realized_net_return_pct < -5


def test_same_bar_double_touch_is_ambiguous_not_optimistically_won():
    data = bars([
        (100, 101, 99, 100),
        (100, 120, 80, 100),
        (100, 101, 99, 100),
        (100, 101, 99, 100),
    ])
    label = build_target_labels(data, token_key="solana:mint", pool_key="pool-a",
                                entry_notional_usd=100, spec=spec())[0]
    assert label.outcome == "AMBIGUOUS_SAME_BAR"
    assert label.realized_net_return_pct is None


def test_complete_path_without_barrier_is_timeout():
    flat = [(100, 101, 99, 100)] * 7
    label = build_target_labels(bars(flat), token_key="solana:mint", pool_key="pool-a",
                                entry_notional_usd=100, spec=spec())[0]
    assert label.outcome == "TIMEOUT"
    assert label.realized_net_return_pct is not None


def test_incomplete_forward_path_is_censored_not_negative():
    flat = [(100, 101, 99, 100)] * 4
    label = build_target_labels(bars(flat), token_key="solana:mint", pool_key="pool-a",
                                entry_notional_usd=100, spec=spec(horizon_ms=5 * 60_000))[0]
    assert label.outcome == "HORIZON_CENSORED"
    assert label.realized_net_return_pct is None


def test_bar_opening_at_horizon_boundary_cannot_create_a_barrier_hit():
    data = bars([
        (100, 101, 99, 100),
        (100, 101, 99, 100),
        (100, 101, 99, 100),
        (100, 101, 99, 100),
        (100, 130, 70, 100),
    ])
    label = build_target_labels(
        data, token_key="solana:mint", pool_key="pool-a",
        entry_notional_usd=100, spec=spec(),
    )[0]
    assert label.outcome == "TIMEOUT"
    assert label.label_end_ts_ms == 240_000
    assert label.realized_net_return_pct is not None
    assert label.realized_net_return_pct < 0


def test_horizon_without_an_exact_boundary_bar_is_censored_not_extended():
    data = bars([(100, 101, 99, 100)] * 7)
    label = build_target_labels(
        data, token_key="solana:mint", pool_key="pool-a",
        entry_notional_usd=100, spec=spec(horizon_ms=150_000),
    )[0]
    assert label.outcome == "HORIZON_CENSORED"
    assert label.realized_net_return_pct is None


def test_missing_or_insufficient_entry_liquidity_is_not_treated_as_zero_return():
    data = bars([(100, 101, 99, 100)] * 5, liquidity=None)
    label = build_target_labels(data, token_key="solana:mint", pool_key="pool-a",
                                entry_notional_usd=100, spec=spec())[0]
    assert label.outcome == "ENTRY_UNAVAILABLE"


def test_missing_exit_liquidity_does_not_count_as_a_winning_opportunity():
    data = bars([
        (100, 101, 99, 100),
        (100, 101, 99, 100),
        (100, 108, 99, 106),
        (106, 108, 104, 107),
    ])
    data[2] = PriceBar(data[2].ts_ms, data[2].open, data[2].high, data[2].low,
                       data[2].close, None)
    label = build_target_labels(data, token_key="solana:mint", pool_key="pool-a",
                                entry_notional_usd=100, spec=spec())[0]
    assert label.outcome == "EXIT_UNAVAILABLE"


def test_input_order_and_ohlc_consistency_are_validated():
    with pytest.raises(ValueError, match="strictly increasing"):
        build_target_labels(
            [PriceBar(60_000, 100, 101, 99, 100, 1_000),
             PriceBar(60_000, 100, 101, 99, 100, 1_000)],
            token_key="solana:mint", pool_key="pool-a", entry_notional_usd=10, spec=spec(),
        )
    with pytest.raises(ValueError, match="inconsistent"):
        build_target_labels(
            [PriceBar(0, 100, 90, 95, 100, 1_000)],
            token_key="solana:mint", pool_key="pool-a", entry_notional_usd=10, spec=spec(),
        )


def test_label_outcome_vocabulary_is_closed():
    assert OUTCOMES == {
        "UPSIDE_FIRST", "DOWNSIDE_FIRST", "TIMEOUT", "AMBIGUOUS_SAME_BAR",
        "ENTRY_UNAVAILABLE", "EXIT_UNAVAILABLE", "HORIZON_CENSORED",
    }


def test_interval_purging_removes_any_training_window_touching_test_window():
    train = [(0, 10), (11, 20), (21, 30), (31, 40)]
    test = [(20, 25)]
    assert intervals_overlap(11, 20, 20, 25)
    assert purge_overlapping_training_indices(train, test) == [0, 3]


def test_interval_purging_rejects_inverted_intervals():
    with pytest.raises(ValueError, match="must not precede"):
        intervals_overlap(5, 4, 1, 2)
