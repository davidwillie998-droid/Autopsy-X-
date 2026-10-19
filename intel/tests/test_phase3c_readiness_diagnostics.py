from __future__ import annotations

import pytest

from autopsyx.research.phase3c_readiness_diagnostics import summarize_timestamps


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
    assert report["missing_intervals_inside_observed_span"] == 1
    assert report["coverage_inside_observed_span"] == pytest.approx(0.8)
    assert report["longest_contiguous_run_bars"] == 2
    assert report["longest_internal_gap_intervals"] == 1
    assert report["misaligned_timestamps"] == 0
    assert report["created_to_last_expected_intervals"] == 5
    assert report["missing_intervals_since_creation"] == 1


def test_empty_bar_history_is_unknown_not_zero_coverage():
    report = summarize_timestamps([], created_ts=0)
    assert report["unique_bars"] == 0
    assert report["missing_intervals_inside_observed_span"] is None
    assert report["coverage_inside_observed_span"] is None
    assert report["longest_contiguous_run_bars"] == 0
    assert report["misaligned_timestamps"] == 0


def test_timestamp_summary_rejects_invalid_interval():
    with pytest.raises(ValueError, match="interval_ms must be positive"):
        summarize_timestamps([0, 60_000], interval_ms=0)


def test_timestamp_summary_flags_off_minute_timestamps():
    report = summarize_timestamps([1_000, 61_000, 121_000], interval_ms=60_000)
    assert report["misaligned_timestamps"] == 3


def test_archived_phase3c_run_exposes_the_historical_backfill_ceiling():
    from pathlib import Path
    from autopsyx.research.phase3c_readiness_diagnostics import audit_archive

    intel_root = Path(__file__).resolve().parents[1]
    archive = intel_root / "datasets" / "phase3c" / "runs" / "p3c-sol-20261004f"
    if not archive.exists():
        pytest.skip("immutable Phase 3C archive not present in this checkout")

    report = audit_archive(archive)
    assert report["diagnostic_only"] is True
    assert report["acquisition_status"] == "COMPLETE"
    assert report["configured_history_cap"]["maximum_requested_minute_bars_per_pool"] == 2_000
    assert report["configured_history_cap"]["maximum_requested_history_hours_per_pool"] == pytest.approx(2000 / 60)
    assert report["run_window"]["completed_cycles"] == 2
    assert report["run_window"]["cycle_count_source"] == "legacy_cycles_field"
    assert report["run_window"]["observed_elapsed_s"] is None
    assert report["request_accounting"]["poll_request_count_matches_cycle_count"] is True
    assert report["selected_pool_count"] > 0
