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


# ------------------------------------------------------------------------------------------
# Provider-shaped stores for point-in-time and missing-data tests. Synthetic values, but the
# same record types, clocks and coverage semantics the real adapters produce.
import math
import random

from autopsyx.core.models import (Coverage, HolderSnapshot, PoolInfo, PoolSnapshot, ProviderBar, Side, Swap,
                                  TokenMeta, TokenRef)
from autopsyx.providers.store import EventStore

T0 = 1_790_000_000_000 - (1_790_000_000_000 % 60_000)
MIN = 60_000
TOKEN = "9sJZFixcrP4WVTXmQ4Rmkbr1LTk9Em5v5A7Y82jtpump"
POOL = "HCikAJCwxbpfE6jGMiGaKQQv9vUkoBpTq5AV9gPnzKPg"
KEY = f"solana:{TOKEN}"
LAG = 60_000


def wallet(i: int) -> str:
    alphabet = "123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz"
    r = random.Random(i)
    return "".join(r.choice(alphabet) for _ in range(44))


def real_path_records(bars=700, jump_at=640, seed=5, trades_from=None, ds_price_skew=0.0, poll_every=1):
    """Minute-by-minute collection as a poller would record it. Everything up to
    minute ``bars`` is 'history'; observation (seen_ts) follows the poll clock:
    each minute m is polled at T0 + (m + 1) * MIN + LAG + 5 s."""
    r = random.Random(seed)
    recs = [TokenMeta(TokenRef("solana", TOKEN), "STONK", "Stonk Inu", T0 - 3 * 86_400_000, None, 1e9, T0,
                      source="geckoterminal", raw_id="r0"),
            PoolInfo("solana", POOL, TOKEN, "pumpswap", T0 - 3 * 86_400_000, T0, "cpmm", 25.0, "geckoterminal", "r0")]
    price, liq = 1e-4, 400_000.0
    trades_from = trades_from if trades_from is not None else 0
    tx = 0
    for m in range(bars):
        t = T0 + m * MIN
        step = r.gauss(0, 0.004) + (0.012 if m >= jump_at else 0.0)
        o = price
        price *= math.exp(step)
        seen = t + MIN + LAG + 5_000
        if m % poll_every:
            seen += (poll_every - m % poll_every) * MIN
        recs.append(ProviderBar("solana", POOL, TOKEN, t, MIN, seen, o, max(o, price) * 1.001, min(o, price) * 0.999,
                                price, 2_000 + r.random() * 500 + (20_000 if m >= jump_at else 0), "geckoterminal", f"b{m}"))
        recs.append(Coverage("solana", TOKEN, POOL, "bars", t - 10 * MIN if m else t - 5 * MIN, t + MIN, seen,
                             "geckoterminal", f"cb{m}"))
        liq *= math.exp(step * 0.5)
        recs.append(PoolSnapshot("solana", POOL, TOKEN, seen, seen, liq, price, "geckoterminal", f"s{m}"))
        recs.append(PoolSnapshot("solana", POOL, TOKEN, seen + 1_000, seen + 1_000, liq * 1.1,
                                 price * (1 + ds_price_skew), "dexscreener", f"d{m}"))
        if m >= trades_from:
            n = 3 + (12 if m >= jump_at else 0)
            for k in range(n):
                tx += 1
                w = wallet(r.randint(0, 40) if m < jump_at else 1000 + tx)
                side = Side.BUY if r.random() < (0.5 if m < jump_at else 0.75) else Side.SELL
                usd = r.uniform(50, 900)
                recs.append(Swap("solana", f"tx{tx}", 0, t + k * 1000, seen, (t + k * 1000) // 400, POOL, TOKEN, w,
                                 side, usd / price, usd, price, "geckoterminal", f"t{m}"))
            recs.append(Coverage("solana", TOKEN, POOL, "trades", t - (MIN if m > trades_from else 0), t + MIN, seen,
                                 "geckoterminal", f"ct{m}"))
        if m % 15 == 0:
            recs.append(HolderSnapshot("solana", TOKEN, t, seen, 900 + m, 0.3, None, "geckoterminal", f"h{m}"))
    return recs


def real_store(**kw) -> EventStore:
    s = EventStore()
    s.extend(real_path_records(**kw))
    return s


def as_of_after(minute: int) -> int:
    """First moment at which minute ``minute`` has been polled."""
    return T0 + (minute + 1) * MIN + LAG + 5_000 + 2_000
