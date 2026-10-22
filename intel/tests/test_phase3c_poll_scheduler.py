"""Phase 3C poll-budget scheduler tests; frozen default behavior remains opt-in."""
from autopsyx.data import acquire
from autopsyx.data.providers import geckoterminal as gt


class FakeFetcher:
    def __init__(self):
        self.calls = []

    def get(self, provider, endpoint, url, context):
        self.calls.append((provider, endpoint, url, context))
        return None, None


def _picked(count):
    return [{"pool": f"pool-{i}", "token": f"token-{i}", "created_ts": 0, "total_supply": 1}
            for i in range(count)]


def _cycle_pools(plan, picked, cycle):
    fetcher = FakeFetcher()
    acquire.poll_cycle(fetcher, plan, picked, cycle)
    reserves = [call for call in fetcher.calls if call[1] == "gt.pools_multi"]
    trades = [call for call in fetcher.calls if call[1] == "gt.trades"]
    ohlcv = [call for call in fetcher.calls if call[1] == "gt.ohlcv"]
    dex = [call for call in fetcher.calls if call[1] == "ds.pairs"]
    assert len(reserves) == 1
    assert len(dex) == 1
    assert len(trades) == len(ohlcv) == plan.poll_pools_per_cycle
    reserve_pools = set(reserves[0][3]["pools"])
    trade_pools = {call[3]["pool"] for call in trades}
    ohlcv_pools = {call[3]["pool"] for call in ohlcv}
    dex_pools = set(dex[0][3]["pool_tokens"])
    assert reserve_pools == trade_pools == ohlcv_pools == dex_pools
    return trade_pools


def test_phase3c_poll_budget_rotates_all_tokens_without_polling_all_each_cycle():
    picked = _picked(20)
    plan = acquire.Plan(poll_pools_per_cycle=5, holders_per_cycle=0)
    visits = []
    for cycle in range(4):
        selected = _cycle_pools(plan, picked, cycle)
        assert len(selected) == 5
        visits.extend(selected)
    assert set(visits) == {p["pool"] for p in picked}
    assert len(visits) == len(set(visits)) == 20


def test_180_pools_at_12_per_cycle_visit_each_pool_once_in_15_cycles():
    picked = _picked(180)
    plan = acquire.Plan(poll_pools_per_cycle=12, holders_per_cycle=0)
    visits = []
    for cycle in range(15):
        selected = _cycle_pools(plan, picked, cycle)
        assert len(selected) == 12
        visits.extend(selected)
    assert len(visits) == 180
    assert len(set(visits)) == 180
    assert set(visits) == {p["pool"] for p in picked}


def test_non_divisible_pool_count_has_fair_wraparound_coverage():
    picked = _picked(23)
    plan = acquire.Plan(poll_pools_per_cycle=12, holders_per_cycle=0)
    counts = {p["pool"]: 0 for p in picked}
    for cycle in range(23):
        for pool in _cycle_pools(plan, picked, cycle):
            counts[pool] += 1
    # Across 23 cycle starts, each pool must be selected exactly 12 times.
    assert set(counts.values()) == {12}


def test_acquisition_refuses_to_overwrite_existing_segment_metadata(tmp_path):
    (tmp_path / "run.json").write_text('{"status": "INCOMPLETE"}')
    try:
        acquire._assert_fresh_run_dir(str(tmp_path))
    except FileExistsError as exc:
        assert "new immutable segment directory" in str(exc)
    else:
        raise AssertionError("existing acquisition segment must not be reused")


def test_acquisition_allows_a_new_empty_segment_directory(tmp_path):
    acquire._assert_fresh_run_dir(str(tmp_path))


def test_poll_budget_none_preserves_existing_all_pool_polling():
    picked = [{"pool": f"pool-{i}", "token": f"token-{i}", "created_ts": 0, "total_supply": 1}
              for i in range(7)]
    plan = acquire.Plan(poll_pools_per_cycle=None, holders_per_cycle=0)
    f = FakeFetcher()
    acquire.poll_cycle(f, plan, picked, 0)
    assert len([call for call in f.calls if call[1] == "gt.trades"]) == 7
    assert len([call for call in f.calls if call[1] == "gt.ohlcv"]) == 7


def test_exhausted_provider_errors_prevent_complete_archive_status():
    status = acquire._completion_status(cadence_pass=True, cycle_overruns=0, errors=1, cycle_s=60)
    assert status == "INCOMPLETE: 1 provider request(s) failed after retries"
    assert status != "COMPLETE"


def test_archive_is_complete_only_when_cadence_cycles_and_requests_pass():
    assert acquire._completion_status(True, 0, 0, 60) == "COMPLETE"
    assert "revisit interval" in acquire._completion_status(False, 0, 0, 60)
    assert "exceeded" in acquire._completion_status(True, 1, 0, 60)
    assert "provider request(s) failed" in acquire._completion_status(True, 0, 3, 60)


def test_cadence_failure_takes_priority_over_other_incomplete_reasons():
    status = acquire._completion_status(cadence_pass=False, cycle_overruns=1, errors=4, cycle_s=60)
    assert status == "INCOMPLETE: pool revisit interval exceeds the frozen 15-minute label horizon"


def test_audit_annotations_do_not_masquerade_as_failed_provider_requests():
    from types import SimpleNamespace

    entries = [
        SimpleNamespace(provider="audit", error="gdelt: symbol shorter than 3 characters"),
        SimpleNamespace(provider="geckoterminal", error="HTTP 429 after retries"),
        SimpleNamespace(provider="dexscreener", error=None),
    ]
    assert acquire._provider_error_count(entries) == 1
    assert acquire._completion_status(True, 0, acquire._provider_error_count(entries), 60) == (
        "INCOMPLETE: 1 provider request(s) failed after retries"
    )


def test_non_provider_audit_annotation_alone_does_not_block_completion():
    from types import SimpleNamespace

    entries = [SimpleNamespace(provider="audit", error="query_not_applicable: short symbol")]
    assert acquire._provider_error_count(entries) == 0
    assert acquire._completion_status(True, 0, acquire._provider_error_count(entries), 60) == "COMPLETE"
