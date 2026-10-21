from autopsyx.research.audit_contiguous_liquidity import audit_pool_snapshots


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
