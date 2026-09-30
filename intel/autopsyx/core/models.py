"""Canonical, provider-independent records.

Timestamps are integer milliseconds since the Unix epoch, UTC.

Every record carries two clocks:
  ``ts``      when the event happened (block time, publication time)
  ``seen_ts`` when this system could first have known about it

Point-in-time queries filter on ``seen_ts``. Using ``ts`` alone is the most
common source of look-ahead leakage in crypto backtests: an API that reports a
swap 40 seconds late did not give you that swap at block time.
"""
from __future__ import annotations

from dataclasses import dataclass, field
from enum import Enum


class Side(str, Enum):
    BUY = "buy"
    SELL = "sell"


class LiquidityKind(str, Enum):
    ADD = "add"
    REMOVE = "remove"


@dataclass(frozen=True)
class TokenRef:
    """Identity is (chain, address). Symbols collide constantly and are display-only."""

    chain: str
    address: str

    @property
    def key(self) -> str:
        return f"{self.chain}:{self.address}"


@dataclass(frozen=True)
class TokenMeta:
    ref: TokenRef
    symbol: str
    name: str
    launch_ts: int | None
    creator: str | None
    total_supply: float | None
    seen_ts: int
    narratives_hint: tuple[str, ...] = ()
    description: str = ""


@dataclass(frozen=True)
class PoolInfo:
    chain: str
    pool: str
    token: str
    venue: str
    created_ts: int
    seen_ts: int
    amm_model: str = "cpmm"  # cpmm | clmm | orderbook | unknown
    fee_bps: float = 30.0


@dataclass(frozen=True)
class Swap:
    chain: str
    tx_hash: str
    log_index: int
    ts: int
    seen_ts: int
    block: int
    pool: str
    token: str
    wallet: str
    side: Side
    token_amount: float
    quote_usd: float
    price_usd: float

    @property
    def uid(self) -> tuple[str, str, int]:
        return (self.chain, self.tx_hash, self.log_index)


@dataclass(frozen=True)
class LiquidityEvent:
    chain: str
    tx_hash: str
    log_index: int
    ts: int
    seen_ts: int
    block: int
    pool: str
    token: str
    kind: LiquidityKind
    usd: float
    provider_wallet: str

    @property
    def uid(self) -> tuple[str, str, int]:
        return (self.chain, self.tx_hash, self.log_index)


@dataclass(frozen=True)
class PoolSnapshot:
    chain: str
    pool: str
    token: str
    ts: int
    seen_ts: int
    liquidity_usd: float
    price_usd: float
    source: str = ""


@dataclass(frozen=True)
class FundingTransfer:
    """Native-asset transfer. Used for shared-funding graph edges."""

    chain: str
    tx_hash: str
    ts: int
    seen_ts: int
    block: int
    src: str
    dst: str
    amount: float


@dataclass(frozen=True)
class HolderSnapshot:
    chain: str
    token: str
    ts: int
    seen_ts: int
    holders: int
    top10_pct: float
    creator_pct: float | None


@dataclass(frozen=True)
class NewsEvent:
    event_id: str
    ts: int  # publication time as claimed by source
    seen_ts: int  # ingestion time
    source: str
    source_tier: int  # 1 = primary/official ... 4 = unverified social
    headline: str
    summary: str = ""
    entities: tuple[str, ...] = ()
    tokens: tuple[str, ...] = ()  # TokenRef.key values
    chains: tuple[str, ...] = ()
    narrative: str = ""
    event_type: str = "OTHER"
    sentiment: float | None = None  # -1..1
    novelty: float | None = None  # 0..1, 1 = first report of this story
    story_id: str = ""  # groups reports of the same underlying story


@dataclass(frozen=True)
class SocialPost:
    post_id: str
    platform: str
    ts: int
    seen_ts: int
    author_id: str
    author_created_ts: int | None
    author_followers: int | None
    text: str
    tokens: tuple[str, ...] = ()
    is_repost: bool = False
    engagement: int = 0


@dataclass
class Bar:
    ts: int  # open time
    interval_ms: int
    open: float | None = None
    high: float | None = None
    low: float | None = None
    close: float | None = None
    volume_usd: float = 0.0
    buy_volume_usd: float = 0.0
    sell_volume_usd: float = 0.0
    trades: int = 0
    buyers: set[str] = field(default_factory=set)
    sellers: set[str] = field(default_factory=set)
    complete: bool = True  # False when the bar overlaps a known data gap

    @property
    def has_price(self) -> bool:
        return self.close is not None
