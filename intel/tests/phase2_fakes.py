"""Offline stand-ins for vendor endpoints, serving captured fixtures."""
import io
import json
import urllib.error
from pathlib import Path

from autopsyx.data import acquire
from autopsyx.data.providers import dexscreener as ds
from autopsyx.data.providers import geckoterminal as gt
from autopsyx.providers.http import CircuitBreaker, HttpClient, TokenBucket

FIX = Path(__file__).resolve().parent / "fixtures" / "phase2"
T_FIX = 1790754800000  # a response time just after the fixtures were captured


def fixture(name: str) -> bytes:
    return (FIX / name).read_bytes()


class _Resp(io.BytesIO):
    status = 200
    headers = {"Content-Type": "application/json"}

    def __enter__(self):
        return self

    def __exit__(self, *a):
        return False


def route(url: str) -> bytes:
    if "dexscreener" in url:
        return fixture("ds_pairs.json")
    if "/trades" in url:
        return fixture("gt_trades.json")
    if "/ohlcv/" in url:
        return fixture("gt_ohlcv.json")
    if "/info" in url:
        return fixture("gt_token_info.json")
    return fixture("gt_pools.json")


class FakeNet:
    """Routes requests to fixtures; ``faults`` maps a URL substring to a list of
    exceptions (or bytes) served before the normal body."""

    def __init__(self, clock, faults=None):
        self.clock = clock
        self.faults = faults or {}
        self.calls = []

    def __call__(self, req, timeout):
        url = req.full_url
        self.calls.append(url)
        self.clock[0] += 150
        for key, queue in self.faults.items():
            if key in url and queue:
                f = queue.pop(0)
                if isinstance(f, Exception):
                    raise f
                return _Resp(f)
        return _Resp(route(url))


def clients(net: FakeNet, clock) -> dict:
    now = lambda: clock[0]
    mk = lambda base: HttpClient(base, TokenBucket(1e6, 1000, clock=lambda: 0.0, sleep=lambda s: None), {},
                                 max_retries=2, sleep=lambda s: None, opener=net,
                                 breaker=CircuitBreaker(50, 1, clock=lambda: 0.0), now_ms=now)
    return {gt.NAME: mk(gt.BASE), ds.NAME: mk(ds.BASE)}


def http_error(code):
    return urllib.error.HTTPError("u", code, "err", {}, None)


def run_fake(tmp, cycles=2, faults=None, plan=None):
    clock = [T_FIX]
    net = FakeNet(clock, faults)
    p = plan or acquire.Plan(strata={"young": 1, "quiet_young": 1, "trending": 0, "established": 0},
                             new_pool_pages=1, backfill_pages=1, cycle_s=60, duration_s=10_000)

    def sleep(s):
        clock[0] += int(s * 1000)

    meta = acquire.run(str(tmp), p, clients(net, clock), now_ms=lambda: clock[0], sleep=sleep, max_cycles=cycles)
    return meta, net
