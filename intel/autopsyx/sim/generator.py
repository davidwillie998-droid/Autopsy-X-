"""Deterministic synthetic market scenarios for tests, replay and demos.

SYNTHETIC DATA. It exercises code paths with known ground truth; it is not
evidence for or against any research hypothesis. Hypotheses are tested on
historical data only (docs/research/08, 14).
"""
from __future__ import annotations

import math
import random
from dataclasses import dataclass

from ..core.models import (
    FundingTransfer,
    HolderSnapshot,
    LiquidityEvent,
    LiquidityKind,
    NewsEvent,
    PoolInfo,
    PoolSnapshot,
    Side,
    SocialPost,
    Swap,
    TokenMeta,
    TokenRef,
)
from ..providers.store import EventStore

T0 = 1_700_000_000_000
MIN = 60_000
CHAIN = "solana"
SWAP_LAG = 2_000
NEWS_LAG = 30_000


@dataclass
class ScenarioSpec:
    address: str
    symbol: str
    name: str
    kind: str  # organic | wash | rug | quiet | follower
    bars: int = 600
    onset_bar: int = 540
    seed: int = 1
    base_liquidity: float = 400_000.0
    follow_of: str | None = None
    lag_bars: int = 3


class _Sim:
    def __init__(self, spec: ScenarioSpec, shared_path: list[float] | None = None):
        self.s = spec
        self.r = random.Random(spec.seed)
        self.recs: list = []
        self.key = f"{CHAIN}:{spec.address}"
        self.creator = f"creator_{spec.address}"
        self.pool = f"pool_{spec.address}"
        self.shared = shared_path
        self._tx = 0

    def tx(self) -> str:
        self._tx += 1
        return f"{self.s.address}_tx{self._tx}"

    def path(self) -> list[float]:
        s, r = self.s, self.r
        rets = [r.gauss(0, 0.004) for _ in range(s.bars)]
        if s.kind in ("organic", "wash"):
            for i in range(s.onset_bar, s.bars):
                rets[i] += 0.009 if s.kind == "organic" else 0.012
        if s.kind == "rug":
            for i in range(s.onset_bar, min(s.bars, s.onset_bar + 10)):
                rets[i] -= 0.08
        if s.kind == "follower" and self.shared:
            for i in range(s.lag_bars, s.bars):
                rets[i] = 0.6 * self.shared[i - s.lag_bars] + r.gauss(0, 0.001)
        price, out = 0.001, []
        for x in rets:
            price *= math.exp(x)
            out.append(price)
        return out

    def run(self) -> tuple[list, list[float]]:
        s, r = self.s, self.r
        supply = 1_000_000_000.0
        launch = T0 - 3 * 86_400_000
        self.recs.append(TokenMeta(TokenRef(CHAIN, s.address), s.symbol, s.name, launch, self.creator, supply, T0))
        self.recs.append(PoolInfo(CHAIN, self.pool, s.address, "raydium", launch, T0, "cpmm", 25.0))
        self.recs.append(PoolInfo(CHAIN, self.pool + "_b", s.address, "orca", launch, T0, "cpmm", 30.0))
        prices = self.path()
        rets = [0.0] + [math.log(prices[i] / prices[i - 1]) for i in range(1, len(prices))]
        onset = s.onset_bar
        background = [f"{s.address}_bg{i}" for i in range(120)]
        for i, w in enumerate(background):
            self.recs.append(FundingTransfer(CHAIN, self.tx(), T0 - 30 * 86_400_000 + i * 3_600_000, T0,
                                             0, f"funder_{s.address}_{i}", w, 2.0))
        cluster = [f"{s.address}_cl{i}" for i in range(8)]
        if s.kind == "wash":
            for i, w in enumerate(cluster):
                ts = T0 + (onset - 30) * MIN + i * 20_000
                self.recs.append(FundingTransfer(CHAIN, self.tx(), ts, ts + SWAP_LAG, ts // 400,
                                                 f"hub_{s.address}", w, 50.0))
        liquidity = s.base_liquidity
        holders = 1500
        new_idx = 0
        for b in range(s.bars):
            t = T0 + b * MIN
            px = prices[b]
            after = b >= onset
            n = r.randint(2, 5)
            if s.kind in ("organic", "follower") and after:
                n += 6 + (b - onset) // 4
            for _ in range(n):
                if s.kind in ("organic", "follower") and after and r.random() < 0.7:
                    w = f"{s.address}_new{new_idx}"
                    new_idx += 1
                    self.recs.append(FundingTransfer(CHAIN, self.tx(), t - 10 * 86_400_000 - new_idx * 7_200_000,
                                                     t - 10 * 86_400_000, 0, f"funder_new_{s.address}_{new_idx}", w, 1.0))
                    side = Side.BUY
                else:
                    w = r.choice(background)
                    side = Side.BUY if r.random() < 0.5 + (0.15 if after and s.kind != "rug" else 0) else Side.SELL
                self._swap(t + r.randint(0, MIN - 1), w, side, r.uniform(50, 800), px)
            if s.kind == "wash" and after:
                # Synchronized round-trips by the funded cluster.
                sec = t + r.randint(0, 50_000)
                for w in cluster:
                    self._swap(sec + r.randint(0, 800), w, Side.BUY, r.uniform(4_000, 6_000), px)
                    self._swap(sec + 5_000 + r.randint(0, 800), w, Side.SELL, r.uniform(4_000, 6_000), px)
            if s.kind == "organic" and after and (b - onset) % 10 == 0:
                lp = f"{s.address}_lp{b}"
                amt = liquidity * 0.03
                liquidity += amt
                self.recs.append(LiquidityEvent(CHAIN, self.tx(), 0, t + 1_000, t + 1_000 + SWAP_LAG, (t + 1_000) // 400,
                                                self.pool, s.address, LiquidityKind.ADD, amt, lp))
            if s.kind == "rug" and b == onset:
                amt = liquidity * 0.8
                liquidity -= amt
                self.recs.append(LiquidityEvent(CHAIN, self.tx(), 0, t + 500, t + 500 + SWAP_LAG, (t + 500) // 400,
                                                self.pool, s.address, LiquidityKind.REMOVE, amt, self.creator))
                for k in range(5):
                    self._swap(t + 1_000 + k * 3_000, self.creator, Side.SELL, 20_000, px)
            liquidity *= math.exp(rets[b] * 0.5)  # pool TVL co-moves with price
            for pool, src, noise in ((self.pool, "vendorA", 0.0), (self.pool + "_b", "vendorB", 0.002)):
                self.recs.append(PoolSnapshot(CHAIN, pool, s.address, t + MIN - 1, t + MIN - 1 + SWAP_LAG,
                                              liquidity * (0.7 if pool == self.pool else 0.3),
                                              px * (1 + r.uniform(-noise, noise)), src))
            if b % 15 == 0:
                if s.kind in ("organic", "follower") and after:
                    holders += 60
                elif s.kind == "rug" and after:
                    holders -= 30
                else:
                    holders += r.randint(-3, 5)
                top10 = 0.72 if s.kind == "wash" else 0.28
                self.recs.append(HolderSnapshot(CHAIN, s.address, t, t + SWAP_LAG, holders, top10,
                                                0.4 if s.kind == "rug" else 0.03))
        self._social(onset)
        if s.kind == "organic":
            ts = T0 + (onset - 3) * MIN
            self.recs.append(NewsEvent("news_" + s.address, ts, ts + NEWS_LAG, "ExchangeX announcements", 1,
                                       f"ExchangeX will list {s.symbol}", tokens=(self.key,), chains=(CHAIN,),
                                       event_type="LISTING", sentiment=0.6, novelty=1.0, story_id="st_" + s.address))
            self.recs.append(NewsEvent("news2_" + s.address, ts + 120_000, ts + 150_000, "CryptoWire", 3,
                                       f"{s.symbol} jumps on ExchangeX listing", tokens=(self.key,),
                                       event_type="LISTING", story_id="st_" + s.address))
        return self.recs, rets

    def _swap(self, ts: int, w: str, side: Side, usd: float, px: float) -> None:
        p = px * (1 + self.r.uniform(-0.001, 0.001))
        self.recs.append(Swap(CHAIN, self.tx(), 0, ts, ts + SWAP_LAG, ts // 400, self.pool, self.s.address, w, side,
                              usd / p, usd, p))

    def _social(self, onset: int) -> None:
        s, r = self.s, self.r
        for b in range(s.bars):
            t = T0 + b * MIN
            if s.kind == "organic" and b >= onset:
                k = 3 + (b - onset) // 3
                for j in range(k):
                    a = f"user_{r.randint(0, 5000)}"
                    self.recs.append(SocialPost(f"{s.address}_p{b}_{j}", "x", t + j * 1000, t + j * 1000 + 5_000, a,
                                                T0 - 400 * 86_400_000, r.randint(50, 20_000),
                                                f"{s.symbol} {r.choice(['listing', 'chart', 'community', 'holders', 'volume'])} "
                                                f"looks {r.choice(['strong', 'early', 'wild', 'clean'])} {r.randint(0, 99999)}",
                                                (self.key,)))
            elif s.kind == "wash" and b >= onset:
                for j in range(20):
                    a = f"bot_{s.address}_{j % 6}"
                    self.recs.append(SocialPost(f"{s.address}_p{b}_{j}", "x", t + j * 500, t + j * 500 + 5_000, a,
                                                t - 2 * 86_400_000, 12,
                                                f"{s.symbol} to the moon 100x gem do not miss", (self.key,)))
            elif r.random() < 0.3:
                self.recs.append(SocialPost(f"{s.address}_p{b}", "x", t, t + 5_000, f"user_{r.randint(0, 5000)}",
                                            T0 - 400 * 86_400_000, r.randint(50, 5_000),
                                            f"anyone holding {s.symbol} {r.randint(0, 99999)}", (self.key,)))


DEFAULT_SCENARIOS = [
    ScenarioSpec("PEPEaddr", "PEPEK", "Pepe King", "organic", seed=11),
    ScenarioSpec("FROGaddr", "FROGP", "Frog Pump", "wash", seed=12),
    ScenarioSpec("HAMSaddr", "HAMR", "Rug Hamster", "rug", seed=13),
    ScenarioSpec("CATZaddr", "CATZ", "Cat Coin", "quiet", seed=14),
    ScenarioSpec("DOGEaddr", "DOGP", "Doge Pal", "follower", seed=15, follow_of="PEPEaddr"),
]


def generate(specs: list[ScenarioSpec] = DEFAULT_SCENARIOS) -> list:
    out, paths = [], {}
    for spec in specs:
        shared = paths.get(spec.follow_of) if spec.follow_of else None
        recs, rets = _Sim(spec, shared).run()
        paths[spec.address] = rets
        out.extend(recs)
    return out


def build_store(specs: list[ScenarioSpec] = DEFAULT_SCENARIOS) -> EventStore:
    store = EventStore()
    store.extend(generate(specs))
    return store


def end_ts(spec: ScenarioSpec = DEFAULT_SCENARIOS[0]) -> int:
    return T0 + spec.bars * MIN
