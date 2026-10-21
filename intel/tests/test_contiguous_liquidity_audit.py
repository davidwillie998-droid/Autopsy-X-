from autopsyx.research.audit_contiguous_liquidity import audit_archive, audit_pool_cycles, audit_pool_snapshots


def test_contiguous_positive_snapshots_pass_all_horizons():
    start = 1_000_000
    cadence = 60_000
    rows = [{"timestamp_ms": start + i * cadence, "liquidity_usd": 12_000.0} for i in range(5)]
    out = audit_pool_snapshots(rows, expected_start_ms=start, expected_end_ms=start + 4 * cadence,
                               expected_cadence_ms=cadence)
    assert out["eligible_all_horizons"] is True
    assert all(v["status"] == "PASS" for v in out["horizons"].values())


def test_missing_snapshots_fail_closed_without_interpolation():
    start = 1_000_000
    cadence = 60_000
    # Missing one expected snapshot creates both an expected-count shortfall and a gap.
    rows = [
        {"timestamp_ms": start, "liquidity_usd": 12_000.0},
        {"timestamp_ms": start + cadence, "liquidity_usd": 12_000.0},
        {"timestamp_ms": start + 3 * cadence, "liquidity_usd": 12_000.0},
        {"timestamp_ms": start + 4 * cadence, "liquidity_usd": 12_000.0},
    ]
    out = audit_pool_snapshots(rows, expected_start_ms=start, expected_end_ms=start + 4 * cadence,
                               expected_cadence_ms=cadence)
    assert out["eligible_all_horizons"] is False
    assert all(v["status"] == "NON_CONTIGUOUS" for v in out["horizons"].values())
    assert all(any("observed snapshots" in reason for reason in v["reasons"]) for v in out["horizons"].values())


def test_gap_larger_than_five_minutes_fails_five_minute_gate():
    start = 1_000_000
    cadence = 60_000
    rows = [
        {"timestamp_ms": start, "liquidity_usd": 10_000.0},
        {"timestamp_ms": start + 60_000, "liquidity_usd": 10_000.0},
        {"timestamp_ms": start + 7 * 60_000, "liquidity_usd": 10_000.0},
    ]
    out = audit_pool_snapshots(rows, expected_start_ms=start, expected_end_ms=start + 7 * 60_000,
                               expected_cadence_ms=cadence)
    assert out["horizons"]["5m"]["status"] == "NON_CONTIGUOUS"
    assert out["horizons"]["15m"]["status"] == "NON_CONTIGUOUS"  # expected count still fails


def test_missing_or_nonpositive_liquidity_fails_closed():
    start = 1_000_000
    rows = [
        {"timestamp_ms": start, "liquidity_usd": 10_000.0},
        {"timestamp_ms": start + 60_000, "liquidity_usd": None},
        {"timestamp_ms": start + 120_000, "liquidity_usd": 0.0},
    ]
    out = audit_pool_snapshots(rows, expected_start_ms=start, expected_end_ms=start + 120_000,
                               expected_cadence_ms=60_000)
    assert out["eligible_all_horizons"] is False
    assert all(v["status"] == "NON_CONTIGUOUS" for v in out["horizons"].values())
    assert out["invalid_liquidity_records"] == 2


def test_duplicate_timestamps_do_not_inflate_observed_count():
    start = 1_000_000
    rows = [
        {"timestamp_ms": start, "liquidity_usd": 10_000.0},
        {"timestamp_ms": start, "liquidity_usd": 11_000.0},
        {"timestamp_ms": start + 60_000, "liquidity_usd": 10_000.0},
    ]
    out = audit_pool_snapshots(rows, expected_start_ms=start, expected_end_ms=start + 60_000,
                               expected_cadence_ms=60_000)
    assert out["horizons"]["5m"]["observed_positive_liquidity_snapshots"] == 2


def test_horizon_gap_thresholds_are_applied_independently():
    start = 1_000_000
    cadence = 6 * 60_000
    rows = [
        {"timestamp_ms": start, "liquidity_usd": 10_000.0},
        {"timestamp_ms": start + cadence, "liquidity_usd": 10_000.0},
    ]
    out = audit_pool_snapshots(rows, expected_start_ms=start, expected_end_ms=start + cadence,
                               expected_cadence_ms=cadence)
    assert out["horizons"]["5m"]["status"] == "NON_CONTIGUOUS"
    assert out["horizons"]["15m"]["status"] == "PASS"
    assert out["horizons"]["60m"]["status"] == "PASS"

def test_out_of_window_snapshots_cannot_mask_missing_live_cycles():
    start = 1_000_000
    cadence = 60_000
    rows = [
        {"timestamp_ms": start - cadence, "liquidity_usd": 12_000.0},  # discovery snapshot
        {"timestamp_ms": start, "liquidity_usd": 12_000.0},
        {"timestamp_ms": start + 2 * cadence, "liquidity_usd": 12_000.0},  # missing cycle at +1m
        {"timestamp_ms": start + 3 * cadence, "liquidity_usd": 12_000.0},
        {"timestamp_ms": start + 4 * cadence, "liquidity_usd": 12_000.0},
        {"timestamp_ms": start + 5 * cadence, "liquidity_usd": 12_000.0},  # post-window
    ]
    out = audit_pool_snapshots(
        rows,
        expected_start_ms=start,
        expected_end_ms=start + 4 * cadence,
        expected_cadence_ms=cadence,
    )
    assert out["out_of_window_records_ignored"] == 2
    assert out["horizons"]["5m"]["observed_positive_liquidity_snapshots"] == 4
    assert out["eligible_all_horizons"] is False
    assert all(v["status"] == "NON_CONTIGUOUS" for v in out["horizons"].values())




def _cycle_rows(cycles, cadence=60_000):
    start = 1_000_000
    return [
        {"cycle": cycle, "timestamp_ms": start + cycle * cadence, "liquidity_usd": 12_000.0}
        for cycle in cycles
    ]


def test_cycle_audit_passes_only_when_every_expected_cycle_has_one_valid_snapshot():
    start = 1_000_000
    out = audit_pool_cycles(
        _cycle_rows([0, 1, 2, 3, 4]),
        expected_cycles=[0, 1, 2, 3, 4],
        expected_start_ms=start,
        expected_end_ms=start + 4 * 60_000,
        expected_cadence_ms=60_000,
    )
    assert out["eligible_all_horizons"] is True
    assert all(v["status"] == "PASS" for v in out["horizons"].values())


def test_extra_snapshot_cannot_mask_missing_expected_cycle():
    start = 1_000_000
    rows = _cycle_rows([0, 1, 2, 2, 4])
    out = audit_pool_cycles(
        rows,
        expected_cycles=[0, 1, 2, 3, 4],
        expected_start_ms=start,
        expected_end_ms=start + 4 * 60_000,
        expected_cadence_ms=60_000,
    )
    assert out["eligible_all_horizons"] is False
    assert out["missing_cycles"] == [2, 3]
    assert out["duplicate_cycles"] == [2]
    assert all(v["status"] == "NON_CONTIGUOUS" for v in out["horizons"].values())


def test_failed_live_poll_fails_closed_even_if_other_cycles_have_snapshots():
    start = 1_000_000
    out = audit_pool_cycles(
        _cycle_rows([0, 1, 3, 4]),
        expected_cycles=[0, 1, 2, 3, 4],
        expected_start_ms=start,
        expected_end_ms=start + 4 * 60_000,
        expected_cadence_ms=60_000,
        failed_cycles={2: "HTTP 429"},
    )
    assert out["eligible_all_horizons"] is False
    assert out["missing_cycles"] == [2]
    assert any("HTTP 429" in v["reason"] for v in out["cycle_results"] if v["cycle"] == 2)


def test_discovery_timestamp_cannot_substitute_for_live_cycle():
    start = 1_000_000
    # Discovery records have no cycle ID and are therefore not observations
    # accepted by audit_pool_cycles, even if their timestamps fill the gap.
    rows = _cycle_rows([0, 1, 3, 4])
    rows.append({"timestamp_ms": start + 2 * 60_000, "liquidity_usd": 12_000.0})
    out = audit_pool_cycles(
        rows,
        expected_cycles=[0, 1, 2, 3, 4],
        expected_start_ms=start,
        expected_end_ms=start + 4 * 60_000,
        expected_cadence_ms=60_000,
    )
    assert out["eligible_all_horizons"] is False
    assert out["missing_cycles"] == [2]



def test_snapshot_timestamp_outside_actual_acquisition_window_fails_closed():
    start = 1_000_000
    rows = _cycle_rows([0, 1, 2, 3, 4])
    rows[-1]["timestamp_ms"] = start + 10 * 60_000
    out = audit_pool_cycles(
        rows,
        expected_cycles=[0, 1, 2, 3, 4],
        expected_start_ms=start,
        expected_end_ms=start + 4 * 60_000,
        expected_cadence_ms=60_000,
    )
    assert out["eligible_all_horizons"] is False
    assert out["missing_cycles"] == [4]
    assert all(v["status"] == "NON_CONTIGUOUS" for v in out["horizons"].values())



def test_archive_audit_is_read_only_when_manifest_is_missing(tmp_path):
    import json
    import pytest

    (tmp_path / "run.json").write_text(json.dumps({"status": "COMPLETE"}), encoding="utf-8")
    with pytest.raises(ValueError, match="manifest missing"):
        audit_archive(tmp_path)
    assert not (tmp_path / "raw").exists()
