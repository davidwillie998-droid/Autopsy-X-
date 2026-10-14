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
