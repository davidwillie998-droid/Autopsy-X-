"""Frozen universe, chained runs and the Phase 3A enrichment pass (offline)."""
import json

import pytest

from autopsyx.data import acquire
from autopsyx.data.normalize3a import normalize_phase3a
from autopsyx.data.providers import news_social as ns
from autopsyx.data.providers import solana_rpc as rpc
from autopsyx.providers.http import CircuitBreaker, HttpClient, TokenBucket

from phase2_fakes import FakeNet, T_FIX, _Resp, clients

DEV = "9WzDXwBbmkg8ZTbNMqUxvQRAyrZzDsGYdLVL9zYtAWWM"


class Net3(FakeNet):
    """Phase 2 fixtures for market data; empty but well-formed answers for RPC,
    GDELT and Reddit; the token info fixture gains a developer address."""

    def __call__(self, req, timeout):
        url = req.full_url
        if "solana.com" in url or "rpc." in url:
            self.calls.append(url)
            self.clock[0] += 100
            m = json.loads(req.data.decode())["method"]
            return _Resp(json.dumps({"jsonrpc": "2.0", "id": 1, "result": [] if m == "getSignaturesForAddress" else None}).encode())
        if "gdeltproject" in url:
            self.calls.append(url)
            return _Resp(b"{}")
        if "reddit" in url:
            self.calls.append(url)
            return _Resp(json.dumps({"data": {"children": []}}).encode())
        r = super().__call__(req, timeout)
        if "/info" in url:
            doc = json.loads(r.getvalue())
            doc["data"]["attributes"]["developer_address"] = DEV
            return _Resp(json.dumps(doc).encode())
        return r


def run3(tmp, seed=20260930, universe_file=None, cycles=1):
    clock = [T_FIX]
    net = Net3(clock)
    cl = clients(net, clock)
    mk = lambda base: HttpClient(base, TokenBucket(1e6, 1000, clock=lambda: 0.0, sleep=lambda s: None), {},
                                 max_retries=1, sleep=lambda s: None, opener=net,
                                 breaker=CircuitBreaker(50, 1, clock=lambda: 0.0), now_ms=lambda: clock[0])
    cl.update({rpc.NAME: mk(rpc.PUBLIC_BASE), ns.GDELT: mk(ns.GDELT_BASE), ns.REDDIT: mk(ns.REDDIT_BASE)})
    p = acquire.Plan(strata={"young": 1, "quiet_young": 1, "trending": 0, "established": 0}, new_pool_pages=1,
                     backfill_pages=1, cycle_s=60, duration_s=10_000, phase3a=True, seed=seed,
                     universe_file=universe_file, rpc_max_pages=1)

    def sleep(s):
        clock[0] += int(s * 1000)
    meta = acquire.run(str(tmp), p, cl, now_ms=lambda: clock[0], sleep=sleep, max_cycles=cycles)
    return meta, net


def test_universe_frozen_before_collection(tmp_path):
    meta, _ = run3(tmp_path)
    u = json.loads((tmp_path / "universe.json").read_text())
    for k in ("frozen_at_ms", "mechanism", "tokens", "pools", "metadata", "exclusions", "fingerprint"):
        assert k in u
    first_collection = min(e.request_ts for e in acquire.RawStore(tmp_path).entries()
                           if e.endpoint not in ("gt.new_pools", "gt.trending", "gt.top_pools"))
    assert u["frozen_at_ms"] <= first_collection
    assert meta["universe"]["source"] == "frozen_this_run" and meta["status"] == "COMPLETE"


def test_same_seed_same_universe(tmp_path):
    run3(tmp_path / "a")
    run3(tmp_path / "b")
    a = json.loads((tmp_path / "a" / "universe.json").read_text())
    b = json.loads((tmp_path / "b" / "universe.json").read_text())
    assert a["fingerprint"] == b["fingerprint"] and a["pools"] == b["pools"]


def test_chained_run_reuses_universe_without_reselecting(tmp_path):
    run3(tmp_path / "a")
    meta, net = run3(tmp_path / "b", universe_file=str(tmp_path / "a" / "universe.json"))
    assert meta["universe"]["source"] == "reused"
    assert not [c for c in net.calls if "new_pools" in c or "trending" in c]
    a = json.loads((tmp_path / "a" / "universe.json").read_text())
    assert json.loads((tmp_path / "b" / "universe.json").read_text()) == a


def test_edited_universe_refused(tmp_path):
    run3(tmp_path / "a")
    path = tmp_path / "a" / "universe.json"
    u = json.loads(path.read_text())
    u["tokens"] = u["tokens"][:-1]
    path.write_text(json.dumps(u))
    with pytest.raises(ValueError, match="fingerprint mismatch"):
        run3(tmp_path / "b", universe_file=str(path))


def test_enrichment_requests_every_source_and_records_outcomes(tmp_path):
    meta, net = run3(tmp_path)
    rounds = {s["round"] for s in meta["enrichment"]}
    assert rounds == {0, 1}
    s = meta["enrichment"][0]
    assert s["funding"]["address"] == DEV and s["liquidity"]["purpose"] == "liquidity"
    eps = {e.endpoint for e in acquire.RawStore(tmp_path).entries()}
    assert {"rpc.signatures", "news.gdelt", "social.reddit"} <= eps
    obs, _ = normalize_phase3a(str(tmp_path))
    kinds = {o.kind for o in obs}
    assert {"news", "social", "creator_state", "holder_state", "liquidity_event"} <= kinds


def test_phase2_plan_writes_no_universe(tmp_path):
    from phase2_fakes import run_fake
    run_fake(tmp_path, cycles=1)
    assert not (tmp_path / "universe.json").exists()
