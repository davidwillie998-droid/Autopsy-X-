from __future__ import annotations

import pytest
from types import SimpleNamespace

from autopsyx.research.phase3d_data_audit import audit_record_coverage

from autopsyx.research.phase3d_targets import (
    CANDIDATE_HORIZONS_MS,
    CANDIDATE_UPSIDE_THRESHOLDS,
    OUTCOMES,
    PriceBar,
    TargetSpec,
    build_target_labels,
    intervals_overlap,
    purge_overlapping_training_indices,
    price_bars_from_point_in_time_records,
    summarize_target_labels,
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





def test_data_readiness_audit_reports_liquidity_and_horizon_coverage():
    provider_bars = [
        SimpleNamespace(ts=i * 60_000, seen_ts=(i + 1) * 60_000, token="mint",
                        pool="pool-a", open=100, high=101, low=99, close=100)
        for i in range(8)
    ]
    snapshots = [
        SimpleNamespace(ts=i * 60_000, seen_ts=i * 60_000, token="mint",
                        pool="pool-a", liquidity_usd=20_000)
        for i in range(8)
    ]
    report = audit_record_coverage(provider_bars, snapshots, max_liquidity_age_ms=60_000)
    assert report["token_count"] == 1
    assert report["token_pool_count"] == 1
    assert report["bar_count"] == 8
    assert report["liquidity_known_bar_count"] == 8
    assert report["pools_sufficient_by_horizon"]["300000"] == 1
    assert report["pools_sufficient_by_horizon"]["900000"] == 0
    assert report["pools_sufficient_by_horizon"]["3600000"] == 0

def test_target_spec_rejects_non_finite_costs_and_thresholds():
    with pytest.raises(ValueError, match="must be finite"):
        spec(fee_bps=float("nan"))
    with pytest.raises(ValueError, match="must be finite"):
        spec(upside_threshold_pct=float("inf"))

def test_point_in_time_join_never_uses_future_or_stale_liquidity():
    bars_in = [
        SimpleNamespace(ts=0, seen_ts=60_000, token="mint", pool="pool",
                        open=100, high=101, low=99, close=100),
        SimpleNamespace(ts=60_000, seen_ts=120_000, token="mint", pool="pool",
                        open=100, high=101, low=99, close=100),
        SimpleNamespace(ts=120_000, seen_ts=180_000, token="mint", pool="pool",
                        open=100, high=101, low=99, close=100),
    ]
    snapshots = [
        SimpleNamespace(ts=0, seen_ts=0, token="mint", pool="pool", liquidity_usd=10_000),
        # This snapshot describes a later state but was not available at bar open.
        SimpleNamespace(ts=120_000, seen_ts=180_000, token="mint", pool="pool", liquidity_usd=50_000),
    ]
    joined = price_bars_from_point_in_time_records(
        bars_in, snapshots, token_key="mint", pool_key="pool", max_liquidity_age_ms=60_000
    )
    assert [b.liquidity_usd for b in joined] == [10_000, 10_000, None]


def test_point_in_time_join_does_not_mix_other_pool_liquidity():
    bar = SimpleNamespace(ts=60_000, seen_ts=120_000, token="mint", pool="pool-a",
                          open=100, high=101, low=99, close=100)
    other_pool = SimpleNamespace(ts=60_000, seen_ts=60_000, token="mint", pool="pool-b",
                                 liquidity_usd=99_000)
    joined = price_bars_from_point_in_time_records(
        [bar], [other_pool], token_key="mint", pool_key="pool-a", max_liquidity_age_ms=60_000
    )
    assert len(joined) == 1
    assert joined[0].liquidity_usd is None

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
    assert label.net_outcome_return_pct is not None
    assert label.net_outcome_return_pct == 5
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



def test_gap_before_barrier_censors_instead_of_counting_a_win():
    data = [
        PriceBar(0, 100, 101, 99, 100, 100_000),
        PriceBar(60_000, 100, 101, 99, 100, 100_000),
        # The 120-second bar is missing; the next bar cannot prove when a barrier hit.
        PriceBar(180_000, 100, 108, 99, 106, 100_000),
        PriceBar(240_000, 106, 108, 104, 107, 100_000),
    ]
    label = build_target_labels(data, token_key="solana:mint", pool_key="pool-a",
                                entry_notional_usd=100, spec=spec())[0]
    assert label.outcome == "HORIZON_CENSORED"
    assert "gap between observed bars" in label.reason

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
    assert label.net_outcome_return_pct is not None
    assert label.net_outcome_return_pct == -5


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
    assert label.net_outcome_return_pct is None


def test_bar_opening_at_horizon_boundary_cannot_create_barrier_hit():
    data = bars([
        (100, 101, 99, 100),
        (100, 101, 99, 100),
        (100, 101, 99, 100),
        (100, 101, 99, 100),
        # This bar opens at the horizon boundary; its later spike is out of horizon.
        (100, 130, 70, 100),
    ])
    label = build_target_labels(
        data, token_key="solana:mint", pool_key="pool-a",
        entry_notional_usd=100, spec=spec(),
    )[0]
    assert label.outcome == "TIMEOUT"
    assert label.label_end_ts_ms == 240_000
    assert label.net_outcome_return_pct is not None
    # Flat expiry open means only assumed costs, not the boundary bar's spike.
    assert label.net_outcome_return_pct < 0


def test_horizon_without_exact_boundary_bar_is_censored_not_extended():
    data = bars([(100, 101, 99, 100)] * 7)
    label = build_target_labels(
        data, token_key="solana:mint", pool_key="pool-a",
        entry_notional_usd=100, spec=spec(horizon_ms=150_000),
    )[0]
    assert label.outcome == "HORIZON_CENSORED"
    assert label.net_outcome_return_pct is None


def test_gap_immediately_before_exact_horizon_boundary_is_censored():
    data = [
        PriceBar(0, 100, 101, 99, 100, 100_000),
        PriceBar(60_000, 100, 101, 99, 100, 100_000),
        PriceBar(120_000, 100, 101, 99, 100, 100_000),
        # 180,000 is missing; exact expiry exists at 240,000.
        PriceBar(240_000, 100, 101, 99, 100, 100_000),
    ]
    label = build_target_labels(
        data, token_key="solana:mint", pool_key="pool-a",
        entry_notional_usd=100, spec=spec(),
    )[0]
    assert label.outcome == "HORIZON_CENSORED"
    assert "gap" in label.reason


def test_complete_path_without_barrier_is_timeout():
    flat = [(100, 101, 99, 100)] * 7
    label = build_target_labels(bars(flat), token_key="solana:mint", pool_key="pool-a",
                                entry_notional_usd=100, spec=spec())[0]
    assert label.outcome == "TIMEOUT"
    assert label.net_outcome_return_pct is not None


def test_incomplete_forward_path_is_censored_not_negative():
    flat = [(100, 101, 99, 100)] * 4
    label = build_target_labels(bars(flat), token_key="solana:mint", pool_key="pool-a",
                                entry_notional_usd=100, spec=spec(horizon_ms=5 * 60_000))[0]
    assert label.outcome == "HORIZON_CENSORED"
    assert label.net_outcome_return_pct is None


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



def test_prevalence_summary_reports_exclusions_and_unique_token_counts():
    data = bars([
        (100, 101, 99, 100),
        (100, 108, 99, 106),
        (106, 108, 104, 107),
        (107, 109, 105, 108),
    ])
    labels = build_target_labels(data, token_key="solana:mint", pool_key="pool-a",
                                 entry_notional_usd=100, spec=spec())
    summary = summarize_target_labels(labels)
    assert summary["row_count"] == len(labels)
    assert summary["unique_token_count"] == 1
    assert summary["unique_token_pool_count"] == 1
    assert sum(summary["outcome_counts"].values()) == len(labels)
    assert summary["excluded_or_unresolved_rows"] + summary["resolved_rows"] == len(labels)
    assert "not independent-token" in summary["warning"]

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
