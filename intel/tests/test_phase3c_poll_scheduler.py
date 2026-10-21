"""Phase 3C poll-budget scheduler tests; frozen default behavior remains opt-in."""
from autopsyx.data import acquire
from autopsyx.data.providers import geckoterminal as gt


class FakeFetcher:
    def __init__(self):
        self.calls = []

    def get(self, provider, endpoint, url, context):
        self.calls.append((provider, endpoint, url, context))
        return None, None


def test_phase3c_poll_budget_rotates_all_tokens_without_polling_all_each_cycle():
    picked = [{"pool": f"pool-{i}", "token": f"token-{i}", "created_ts": 0, "total_supply": 1}
              for i in range(20)]
    plan = acquire.Plan(poll_pools_per_cycle=5, holders_per_cycle=0)
    seen = []
    for cycle in range(4):
        f = FakeFetcher()
        acquire.poll_cycle(f, plan, picked, cycle)
        multi_calls = [call for call in f.calls if call[1] == "gt.pools_multi"]
        assert len(multi_calls) == 1
        assert multi_calls[0][3]["cycle"] == cycle
        assert multi_calls[0][3]["pools"] == [p["pool"] for p in picked]
        trade_calls = [call for call in f.calls if call[1] == "gt.trades"]
        ohlcv_calls = [call for call in f.calls if call[1] == "gt.ohlcv"]
        assert len(trade_calls) == 5
        assert len(ohlcv_calls) == 5
        tokens = [call[3]["token"] for call in trade_calls]
        assert len(set(tokens)) == 5
        seen.extend(tokens)
    assert set(seen) == {p["token"] for p in picked}
    assert len(seen) == 20


def test_poll_budget_none_preserves_existing_all_pool_polling():
    picked = [{"pool": f"pool-{i}", "token": f"token-{i}", "created_ts": 0, "total_supply": 1}
              for i in range(7)]
    plan = acquire.Plan(poll_pools_per_cycle=None, holders_per_cycle=0)
    f = FakeFetcher()
    acquire.poll_cycle(f, plan, picked, 0)
    assert len([call for call in f.calls if call[1] == "gt.trades"]) == 7
    assert len([call for call in f.calls if call[1] == "gt.ohlcv"]) == 7
