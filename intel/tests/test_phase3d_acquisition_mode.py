from __future__ import annotations

from autopsyx.data.acquire import Plan, poll_cycle


class RecordingFetcher:
    def __init__(self):
        self.calls = []

    def get(self, provider, endpoint, path, context, payload=None):
        self.calls.append((provider, endpoint, path, context))
        return None, b"{}"


def test_phase3d_coverage_mode_prioritizes_synchronized_snapshot_and_ohlcv():
    plan = Plan(
        phase3d_coverage_mode=True,
        cycle_s=60,
        gt_rate_per_s=0.2,
        strata={"young": 2, "quiet_young": 1, "trending": 1, "established": 1},
    )
    picked = [
        {"pool": f"pool-{i}", "token": f"token-{i}", "created_ts": 0, "total_supply": 1}
        for i in range(5)
    ]
    fetcher = RecordingFetcher()

    poll_cycle(fetcher, plan, picked, cycle=7)

    endpoints = [call[1] for call in fetcher.calls]
    assert endpoints.count("gt.pools_multi") == 1
    assert endpoints.count("gt.ohlcv") == len(picked)
    assert "gt.trades" not in endpoints
    assert "ds.pairs" not in endpoints
    assert "gt.token_info" not in endpoints
    assert len(fetcher.calls) == len(picked) + 1

def test_configured_duration_is_reserved_for_live_polling(tmp_path):
    # Backfill/discovery advance the fake clock, but cannot consume the live window.
    from autopsyx.data import acquire
    from phase2_fakes import run_fake

    plan = Plan(
        phase3d_coverage_mode=True,
        strata={"young": 1, "quiet_young": 0, "trending": 0, "established": 0},
        new_pool_pages=1,
        backfill_pages=1,
        cycle_s=0,
        duration_s=0.5,
    )
    meta, _ = run_fake(tmp_path, cycles=None, plan=plan)
    # The fake transport advances 150 ms per request, so a 500 ms live window
    # may legitimately fit more than one cycle. The invariant is that polling
    # starts after discovery/backfill and does not end with zero cycles.
    assert meta["cycles"] >= 1
    assert meta["poll_started_ms"] > meta["started_ms"]
    assert meta["poll_ended_ms"] >= meta["poll_started_ms"]
    assert meta["poll_duration_s"] >= 0
    assert len(meta["cycle_telemetry"]) == meta["cycles"]
    for cycle in meta["cycle_telemetry"]:
        assert cycle["ended_ms"] >= cycle["started_ms"]
        assert cycle["duration_ms"] == cycle["ended_ms"] - cycle["started_ms"]
        assert cycle["requests"] >= 1
        assert cycle["errors"] >= 0
        assert cycle["cadence_overrun_ms"] >= 0
        assert cycle["pool_count"] == 1


def test_phase3d_request_excludes_historical_bars_without_point_in_time_liquidity():
    # GeckoTerminal does not provide historical liquidity snapshots. Backfilled
    # OHLCV could inflate apparent price/liquidity overlap unless every consumer
    # applies seen_ts correctly, so this coverage run deliberately excludes it.
    # Eligibility must be established by fresh, synchronized live observations.
    import json
    from pathlib import Path

    request_path = Path(__file__).resolve().parents[1] / "datasets" / "phase3c" / "REQUEST.json"
    request = json.loads(request_path.read_text(encoding="utf-8"))

    assert request["phase3d_coverage_mode"] is True
    assert request["backfill_pages"] == 0
    assert request["poll_ohlcv_limit"] == 5
    assert request["lag_ms"] >= 60_000
    assert request["duration_s"] >= 3600
