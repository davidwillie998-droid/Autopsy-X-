"""Provider abstraction.

The engine never talks to a vendor API directly. Adapters translate vendor
payloads into canonical records (core.models) and stamp ``seen_ts``. Swapping
DexScreener for Birdeye, or Helius for a self-hosted RPC, touches one adapter
and nothing downstream.
"""
from __future__ import annotations

from dataclasses import dataclass
from typing import Protocol, Sequence, runtime_checkable

from ..core.models import (
    FundingTransfer,
    HolderSnapshot,
    LiquidityEvent,
    NewsEvent,
    PoolInfo,
    PoolSnapshot,
    SocialPost,
    Swap,
    TokenMeta,
)


@dataclass(frozen=True)
class ProviderHealth:
    name: str
    ok: bool
    last_success_ts: int | None
    last_error: str = ""
    rate_limited: bool = False


@runtime_checkable
class DiscoveryProvider(Protocol):
    name: str

    def tokens(self, chain: str, since_ts: int, until_ts: int) -> Sequence[TokenMeta]: ...
    def pools(self, chain: str, token: str) -> Sequence[PoolInfo]: ...


@runtime_checkable
class MarketDataProvider(Protocol):
    name: str

    def swaps(self, chain: str, token: str, since_ts: int, until_ts: int) -> Sequence[Swap]: ...
    def pool_snapshots(self, chain: str, token: str, since_ts: int, until_ts: int) -> Sequence[PoolSnapshot]: ...
    def liquidity_events(self, chain: str, token: str, since_ts: int, until_ts: int) -> Sequence[LiquidityEvent]: ...


@runtime_checkable
class OnChainProvider(Protocol):
    name: str

    def funding_transfers(self, chain: str, wallets: Sequence[str], until_ts: int) -> Sequence[FundingTransfer]: ...
    def holder_snapshots(self, chain: str, token: str, since_ts: int, until_ts: int) -> Sequence[HolderSnapshot]: ...


@runtime_checkable
class NewsProvider(Protocol):
    name: str

    def events(self, since_ts: int, until_ts: int) -> Sequence[NewsEvent]: ...


@runtime_checkable
class SocialProvider(Protocol):
    name: str

    def posts(self, token_key: str, since_ts: int, until_ts: int) -> Sequence[SocialPost]: ...


class ProviderError(RuntimeError):
    """Raised by adapters. Carries whether the failure is retryable."""

    def __init__(self, message: str, retryable: bool = False, rate_limited: bool = False, attempt_log: tuple = ()):
        super().__init__(message)
        self.retryable = retryable
        self.rate_limited = rate_limited
        self.attempt_log = attempt_log
