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
def test_immutable_archive_baseline_metadata(archive_name, expected_cycles, expected_bar_rows, expected_malformed):
    import json
    from pathlib import Path

    intel_root = Path(__file__).resolve().parents[1]
    archive = intel_root / "datasets" / "phase3c" / "runs" / archive_name
    if not archive.exists():
        pytest.skip("immutable Phase 3C archive not present in this checkout")

    run = json.loads((archive / "run.json").read_text(encoding="utf-8"))
    summary = json.loads((archive / "normalize_stdout.json").read_text(encoding="utf-8"))
    assert run["status"] == "COMPLETE"
    assert run["cycles"] == expected_cycles
    assert summary["records"]["ProviderBar"] == expected_bar_rows
    assert summary["issues"]["MALFORMED_RECORD"] == expected_malformed


def test_immutable_phase3c_run_f_readiness_diagnostic_and_endpoint_attribution():
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
    assert report["request_accounting"]["parsed_bar_rows"] == 5_629
    assert "MALFORMED_RECORD" not in report["request_accounting"]["parser_issue_counts"]
    assert report["selected_pool_count"] == 14

    replay = report["normalization_replay"]
    assert replay["stored_summary_present"] is True
    assert replay["stored_vs_recomputed_match"] is True
    assert replay["recomputed_issue_counts"]["MALFORMED_RECORD"] == 481
    assert len(replay["issue_samples"].get("MALFORMED_RECORD", [])) <= 5

    attribution = report["normalization_issue_attribution"]
    unsupported_count = attribution["unsupported_endpoint_response_count"]
    residual_count = attribution["malformed_record_residual_count_after_unsupported_endpoints"]
    assert attribution["unsupported_endpoint_response_counts"] == {
        "news.gdelt": 16,
        "rpc.signatures": 56,
        "rpc.transaction": 409,
    }
    assert unsupported_count == 481
    assert residual_count == 0
    assert unsupported_count + residual_count == 481
    assert attribution["malformed_record_issues_fully_explained_by_unsupported_endpoints"] is True
    samples = replay["issue_samples"]["MALFORMED_RECORD"]
    assert all(sample["classification"] == "UNSUPPORTED_NORMALIZER_ENDPOINT" for sample in samples)
    assert all(sample["endpoint"] in {"rpc.signatures", "rpc.transaction"} for sample in samples)

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


from types import SimpleNamespace

from autopsyx.data.raw import RawStore
from autopsyx.research.phase3c_readiness_diagnostics import (
    audit_archive,
    audit_raw_archive_integrity,
    classify_historical_signal_readiness,
    summarize_provider_reliability,
    summarize_transaction_history,
)


def manifest_entry(**overrides):
    base = {
        "seq": 1, "provider": "test-provider", "endpoint": "test.endpoint",
        "url": "https://example.invalid", "request_ts": 1000, "response_ts": 1100,
        "status": 200, "raw_id": "a" * 64, "bytes": 10, "attempts": 1,
        "error": None, "context": {}, "attempt_log": [], "method": "GET",
        "request_body_sha256": None,
    }
    base.update(overrides)
    return SimpleNamespace(**base)


def test_provider_reliability_separates_final_success_from_retry_pressure():
    entries = [
        manifest_entry(seq=1, attempts=3, attempt_log=[
            {"status": 429, "error": "HTTPError 429", "wait_s": 2.0, "latency_ms": 50},
            {"status": 429, "error": "HTTPError 429", "wait_s": 4.0, "latency_ms": 60},
        ]),
        manifest_entry(seq=2, status=None, raw_id=None, response_ts=None,
                       attempts=2, error="HTTP 403", attempt_log=[
                           {"status": 403, "error": "HTTPError 403", "wait_s": 0, "latency_ms": 30},
                       ]),
        manifest_entry(seq=3, provider="audit", endpoint="query_not_applicable",
                       status=None, raw_id=None, error="not applicable"),
    ]
    report = summarize_provider_reliability(entries)
    assert report["status"] == "DEGRADED"
    assert report["overall"]["requests"] == 2
    assert report["overall"]["terminal_successes"] == 1
    assert report["overall"]["terminal_errors"] == 1
    assert report["overall"]["requests_retried"] == 2
    assert report["overall"]["retry_attempt_status_counts"] == {"403": 1, "429": 2}
    assert report["by_provider"]["test-provider"]["terminal_success_rate"] == 0.5


def test_transaction_history_reports_truncation_even_when_requested_bodies_succeeded():
    run_meta = {
        "enrichment": [{
            "funding": {
                "address": "wallet-1", "signatures": 100, "transactions_requested": 8,
                "signatures_not_fetched": 92, "history_truncated": True, "pagination_gap": None,
            }
        }]
    }
    entries = [
        manifest_entry(seq=1, provider="solana_rpc", endpoint="rpc.signatures",
                       context={"purpose": "funding", "address": "wallet-1"}),
        *[
            manifest_entry(seq=i + 2, provider="solana_rpc", endpoint="rpc.transaction",
                           context={"purpose": "funding", "address": "wallet-1", "signature": f"sig-{i}"})
            for i in range(8)
        ],
    ]
    report = summarize_transaction_history(run_meta, entries)
    assert report["status"] == "INCOMPLETE"
    funding = report["by_purpose"]["funding"]
    assert funding["transaction_body_request_count"] == 8
    assert funding["transaction_bodies_successfully_returned"] == 8
    assert funding["signatures_not_fetched_reported"] == 92
    assert funding["history_truncated_sample_count"] == 1
    assert "one or more discovered signatures were not fetched" in report["incomplete_reasons"]


def test_archive_integrity_reconciles_rpc_request_bodies_as_well_as_responses(tmp_path):
    raw = RawStore(tmp_path)
    raw.record(
        provider="solana_rpc", endpoint="rpc.transaction", url="https://example.invalid",
        request_ts=1000, response_ts=1100, status=200, body=b'{"result": {}}',
        attempts=1, error=None, context={"purpose": "funding"},
        request_body=b'{"method":"getTransaction"}',
    )
    entries = raw.entries()
    report = audit_raw_archive_integrity(tmp_path, entries, raw)
    assert report["status"] == "PASS"
    assert report["response_body_reference_count"] == 1
    assert report["request_body_reference_count"] == 1
    assert report["unique_referenced_body_count"] == 2
    assert report["raw_file_count"] == 2
    assert report["unreferenced_raw_files"] == []


def test_historical_readiness_uses_frozen_protocol_and_defers_pooled_sample():
    from autopsyx.research import phase3b_contract

    report = classify_historical_signal_readiness(
        {"status": "PASS"},
        {"status": "HEALTHY"},
        {"status": "SAMPLED_COMPLETE"},
        {"stored_vs_recomputed_match": True},
        {"pool-1": {"unique_bars": 10}},
    )
    assert report["status"] == "NOT_READY"
    assert report["eligible_pool_count"] is None
    assert report["eligibility_count_status"] == "NOT_EVALUATED_BY_SINGLE_ARCHIVE_DIAGNOSTIC"
    assert report["pool_level_eligibility_policy"] == (
        "NO_ADDITIONAL_LIQUIDITY_FLOOR_OR_PER_TOKEN_MINIMUM_IN_FROZEN_PHASE3C_PROTOCOL"
    )
    assert report["minimum_distinct_tokens_required"] is phase3b_contract.MIN_SAMPLE
    assert report["minimum_distinct_tokens_required"] == 85
    assert report["distinct_token_sample_status"] == "REQUIRES_CROSS_ARCHIVE_PHASE3C_PIPELINE"
    assert any("cross-archive Phase 3C statistical evaluation" in reason for reason in report["blockers"])
    assert not any("no approved Phase 3C numeric" in reason for reason in report["blockers"])
    assert report["quality_warnings"] == []
    assert report["provider_reliability_status"] == "HEALTHY"
    assert report["transaction_history_status"] == "SAMPLED_COMPLETE"


def test_optional_provider_and_transaction_gaps_are_warnings_not_global_gates():
    report = classify_historical_signal_readiness(
        {"status": "PASS"},
        {"status": "DEGRADED"},
        {"status": "INCOMPLETE"},
        {"stored_vs_recomputed_match": True},
        {"pool-1": {"unique_bars": 10}},
    )
    assert report["status"] == "NOT_READY"
    assert report["provider_reliability_status"] == "DEGRADED"
    assert report["transaction_history_status"] == "INCOMPLETE"
    assert any("provider reliability is degraded" in item for item in report["quality_warnings"])
    assert any("transaction history is incomplete" in item for item in report["quality_warnings"])
    assert not any("provider reliability" in item for item in report["blockers"])
    assert not any("transaction-history samples" in item for item in report["blockers"])
    assert any("cross-archive Phase 3C statistical evaluation" in item for item in report["blockers"])


def test_latest_phase3c_archive_has_explicit_evidence_readiness_verdict():
    from pathlib import Path

    intel_root = Path(__file__).resolve().parents[1]
    archive = intel_root / "datasets" / "phase3c" / "runs" / "p3c-sol-20261019a"
    if not archive.exists():
        pytest.skip("latest immutable Phase 3C archive not present in this checkout")
    report = audit_archive(archive)
    assert report["archive_integrity"]["status"] == "PASS"
    assert report["archive_integrity"]["manifest_entry_count"] == 748
    assert report["archive_integrity"]["raw_file_count"] == 560
    assert report["archive_integrity"]["unique_referenced_body_count"] == 560
    assert report["provider_reliability"]["status"] == "DEGRADED"
    assert report["provider_reliability"]["overall"]["terminal_errors"] == 17
    assert report["transaction_history_completeness"]["status"] == "INCOMPLETE"
    assert report["transaction_history_completeness"]["totals"]["signatures_not_fetched_reported"] > 0
    assert report["historical_signal_readiness"]["status"] == "NOT_READY"
    assert report["normalization_replay"]["stored_vs_recomputed_match"] is True
