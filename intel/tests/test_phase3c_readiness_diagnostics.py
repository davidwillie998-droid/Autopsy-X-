from __future__ import annotations

import pytest

from autopsyx.research.phase3c_readiness_diagnostics import conservative_coverage_intervals, summarize_coverage_intervals, summarize_timestamps


def test_timestamp_summary_exposes_internal_gaps_and_duplicates():
    report = summarize_timestamps(
        [0, 60_000, 60_000, 180_000, 240_000],
        created_ts=0,
        interval_ms=60_000,
    )
    assert report["observed_rows"] == 5
    assert report["unique_bars"] == 4
    assert report["duplicate_rows"] == 1
    assert report["observed_span_intervals"] == 5
    assert report["nonempty_bar_slots_without_observation"] == 1
    assert report["bar_density_inside_observed_span"] == pytest.approx(0.8)
    assert report["longest_consecutive_nonempty_bar_run"] == 2
    assert report["longest_gap_between_nonempty_bars_minutes"] == 1
    assert report["misaligned_timestamps"] == 0
    assert report["created_to_last_expected_intervals"] == 5
    assert report["nonempty_bar_slots_without_observation_since_creation"] == 1


def test_empty_bar_history_is_unknown_not_zero_coverage():
    report = summarize_timestamps([], created_ts=0)
    assert report["unique_bars"] == 0
    assert report["nonempty_bar_slots_without_observation"] is None
    assert report["bar_density_inside_observed_span"] is None
    assert report["longest_consecutive_nonempty_bar_run"] == 0
    assert report["misaligned_timestamps"] == 0


def test_timestamp_summary_rejects_invalid_interval():
    with pytest.raises(ValueError, match="interval_ms must be positive"):
        summarize_timestamps([0, 60_000], interval_ms=0)


def test_timestamp_summary_flags_off_minute_timestamps():
    report = summarize_timestamps([1_000, 61_000, 121_000], interval_ms=60_000)
    assert report["misaligned_timestamps"] == 3


@pytest.mark.parametrize(
    ("archive_name", "expected_cycles", "expected_bar_rows", "expected_malformed"),
    [
        ("p3c-sol-20261004e", 0, 8_102, 2_300),
        ("p3c-sol-20261004f", 2, 5_629, 481),
    ],
)
def test_immutable_archived_phase3c_runs_expose_readiness_limits(
    archive_name, expected_cycles, expected_bar_rows, expected_malformed,
):
    from pathlib import Path
    from autopsyx.research.phase3c_readiness_diagnostics import audit_archive

    intel_root = Path(__file__).resolve().parents[1]
    archive = intel_root / "datasets" / "phase3c" / "runs" / archive_name
    if not archive.exists():
        pytest.skip("immutable Phase 3C archive not present in this checkout")

    report = audit_archive(archive)
    assert report["diagnostic_only"] is True
    assert report["acquisition_status"] == "COMPLETE"
    assert report["configured_history_cap"]["maximum_requested_minute_bars_per_pool"] == 2_000
    assert report["configured_history_cap"]["maximum_requested_history_hours_per_pool"] == pytest.approx(2000 / 60)
    assert report["run_window"]["completed_cycles"] == expected_cycles
    assert report["run_window"]["cycle_count_source"] == "legacy_cycles_field"
    assert report["run_window"]["observed_elapsed_s"] is None
    assert report["request_accounting"]["poll_request_count_matches_cycle_count"] is True
    assert report["request_accounting"]["parsed_bar_rows"] == expected_bar_rows
    assert "MALFORMED_RECORD" not in report["request_accounting"]["parser_issue_counts"]
    assert report["selected_pool_count"] > 0
    replay = report["normalization_replay"]
    assert replay["stored_summary_present"] is True
    assert replay["stored_vs_recomputed_match"] is True
    assert replay["recomputed_issue_counts"]["MALFORMED_RECORD"] == expected_malformed
    assert len(replay["issue_samples"].get("MALFORMED_RECORD", [])) <= 5
    attribution = report["normalization_issue_attribution"]
    unsupported_count = attribution["unsupported_endpoint_response_count"]
    residual_count = attribution["malformed_record_residual_count_after_unsupported_endpoints"]
    assert unsupported_count > 0
    assert residual_count >= 0
    assert unsupported_count + residual_count == expected_malformed
    samples = replay["issue_samples"]["MALFORMED_RECORD"]
    assert all(sample["classification"] == "UNSUPPORTED_NORMALIZER_ENDPOINT" for sample in samples)
    assert all(sample["endpoint"] in {"rpc.signatures", "rpc.transaction"} for sample in samples)
    if archive_name == "p3c-sol-20261004f":
        endpoints = report["endpoint_accounting"]
        assert endpoints["news.gdelt"]["failed_requests"] == 12
        assert endpoints["news.gdelt"]["failure_classes"] == {"HTTP_429": 12}
        assert endpoints["social.reddit"]["failed_requests"] == 28
        assert endpoints["social.reddit"]["failure_classes"] == {"HTTP_403": 28}
        assert endpoints["gt.ohlcv"]["failed_requests"] == 0


def test_coverage_claims_merge_overlap_and_report_only_true_uncovered_gaps():
    report = summarize_coverage_intervals([(0, 120), (60, 180), (300, 360)])
    assert report["audited_interval_count"] == 3
    assert report["coverage_union_ms"] == 240
    assert report["uncovered_gap_count"] == 1
    assert report["longest_uncovered_gap_ms"] == 120
    assert report["coverage_union_ratio_inside_claim_span"] == pytest.approx(2 / 3)


def test_no_coverage_claim_is_unknown_not_zero_coverage():
    report = summarize_coverage_intervals([])
    assert report["audited_interval_count"] == 0
    assert report["coverage_union_ratio_inside_claim_span"] is None
    assert report["uncovered_gap_count"] is None


def test_backfill_coverage_is_clipped_to_returned_historical_bars():
    # The frozen parser's generic claim ends at response time, which can
    # overstate coverage for a before_timestamp historical page.
    result = conservative_coverage_intervals(
        [120_000, 180_000, 240_000], [(120_000, 900_000)], is_backfill=True,
    )
    assert result == [(120_000, 300_000)]


def test_live_poll_coverage_keeps_provider_completeness_claim():
    result = conservative_coverage_intervals(
        [120_000, 180_000], [(120_000, 600_000)], is_backfill=False,
    )
    assert result == [(120_000, 600_000)]


def test_backfill_page_without_valid_bars_claims_no_coverage():
    result = conservative_coverage_intervals([], [(0, 600_000)], is_backfill=True)
    assert result == []
