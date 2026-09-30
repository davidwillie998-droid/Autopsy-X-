"""Point-in-time event store.

Holds every canonical record and answers queries *as of* a moment. A record is
visible at ``as_of`` only when ``seen_ts <= as_of``. Backtests, live scans and
replay tests all read through ``view(as_of)``; there is no other door.
"""
from __future__ import annotations

import bisect
import json
from dataclasses import asdict, dataclass, field
from pathlib import Path
from typing import Iterable

from ..core.models import (
    Coverage,
    FundingTransfer,
    HolderSnapshot,
    LiquidityEvent,
    LiquidityKind,
    NewsEvent,
    PoolInfo,
    PoolSnapshot,
    ProviderBar,
    Side,
    SocialPost,
    Swap,
    TokenMeta,
    TokenRef,
)

_KINDS = {
    "token": TokenMeta,
    "pool": PoolInfo,
    "swap": Swap,
    "liquidity": LiquidityEvent,
    "snapshot": PoolSnapshot,
    "funding": FundingTransfer,
    "holders": HolderSnapshot,
    "news": NewsEvent,
    "social": SocialPost,
    "bar": ProviderBar,
    "coverage": Coverage,
}


class _Series:
    """Records sorted by seen_ts for O(log n) point-in-time cuts."""

    def __init__(self) -> None:
        self._keys: list[int] = []
        self._items: list = []

    def add(self, item) -> None:
        i = bisect.bisect_right(self._keys, item.seen_ts)
        self._keys.insert(i, item.seen_ts)
        self._items.insert(i, item)

    def upto(self, as_of: int) -> list:
        return self._items[: bisect.bisect_right(self._keys, as_of)]

    def __len__(self) -> int:
        return len(self._items)


@dataclass
class EventStore:
    tokens: _Series = field(default_factory=_Series)
    pools: _Series = field(default_factory=_Series)
    news: _Series = field(default_factory=_Series)
    funding: _Series = field(default_factory=_Series)
    swaps: dict[str, _Series] = field(default_factory=dict)
    liquidity: dict[str, _Series] = field(default_factory=dict)
    snapshots: dict[str, _Series] = field(default_factory=dict)
    holders: dict[str, _Series] = field(default_factory=dict)
    social: dict[str, _Series] = field(default_factory=dict)
    bars: dict[str, _Series] = field(default_factory=dict)
    coverage: dict[str, _Series] = field(default_factory=dict)

    def add(self, rec) -> None:
        if isinstance(rec, TokenMeta):
            self.tokens.add(rec)
        elif isinstance(rec, PoolInfo):
            self.pools.add(rec)
        elif isinstance(rec, NewsEvent):
            self.news.add(rec)
        elif isinstance(rec, FundingTransfer):
            self.funding.add(rec)
        elif isinstance(rec, Swap):
            self.swaps.setdefault(f"{rec.chain}:{rec.token}", _Series()).add(rec)
        elif isinstance(rec, LiquidityEvent):
            self.liquidity.setdefault(f"{rec.chain}:{rec.token}", _Series()).add(rec)
        elif isinstance(rec, PoolSnapshot):
            self.snapshots.setdefault(f"{rec.chain}:{rec.token}", _Series()).add(rec)
        elif isinstance(rec, HolderSnapshot):
            self.holders.setdefault(f"{rec.chain}:{rec.token}", _Series()).add(rec)
        elif isinstance(rec, SocialPost):
            for t in rec.tokens:
                self.social.setdefault(t, _Series()).add(rec)
        elif isinstance(rec, ProviderBar):
            self.bars.setdefault(f"{rec.chain}:{rec.token}", _Series()).add(rec)
        elif isinstance(rec, Coverage):
            self.coverage.setdefault(f"{rec.chain}:{rec.token}", _Series()).add(rec)
        else:
            raise TypeError(f"unsupported record {type(rec).__name__}")

    def extend(self, recs: Iterable) -> None:
        for r in recs:
            self.add(r)

    def view(self, as_of: int) -> "PointInTimeView":
        return PointInTimeView(self, as_of)

    # --- JSONL persistence (versioned dataset format) -----------------------
    @staticmethod
    def dump_jsonl(path: str | Path, records: Iterable) -> None:
        with open(path, "w") as fh:
            for r in records:
                kind = next(k for k, cls in _KINDS.items() if isinstance(r, cls))
                # "_type" (not "kind"): Coverage and LiquidityEvent have their own "kind" field,
                # which silently overwrote the record type under the Phase 1 envelope.
                fh.write(json.dumps({**_encode(asdict(r)), "_type": kind}, sort_keys=True) + "\n")

    @classmethod
    def load_jsonl(cls, path: str | Path) -> "EventStore":
        store = cls()
        with open(path) as fh:
            for line in fh:
                if line.strip():
                    store.add(decode_record(json.loads(line)))
        return store


class PointInTimeView:
    """Read-only slice of the store. Nothing with seen_ts > as_of is reachable."""

    def __init__(self, store: EventStore, as_of: int):
        self._s = store
        self.as_of = as_of

    def tokens(self) -> list[TokenMeta]:
        # Latest metadata per token as of now; earlier copies are superseded.
        latest: dict[str, TokenMeta] = {}
        for t in self._s.tokens.upto(self.as_of):
            latest[t.ref.key] = t
        return list(latest.values())

    def pools(self, token_key: str) -> list[PoolInfo]:
        return [p for p in self._s.pools.upto(self.as_of) if f"{p.chain}:{p.token}" == token_key]

    def swaps(self, token_key: str) -> list[Swap]:
        s = self._s.swaps.get(token_key)
        return sorted(s.upto(self.as_of), key=lambda x: (x.ts, x.log_index)) if s else []

    def liquidity_events(self, token_key: str) -> list[LiquidityEvent]:
        s = self._s.liquidity.get(token_key)
        return sorted(s.upto(self.as_of), key=lambda x: x.ts) if s else []

    def pool_snapshots(self, token_key: str) -> list[PoolSnapshot]:
        s = self._s.snapshots.get(token_key)
        return sorted(s.upto(self.as_of), key=lambda x: x.ts) if s else []

    def holder_snapshots(self, token_key: str) -> list[HolderSnapshot]:
        s = self._s.holders.get(token_key)
        return sorted(s.upto(self.as_of), key=lambda x: x.ts) if s else []

    def funding(self) -> list[FundingTransfer]:
        return self._s.funding.upto(self.as_of)

    def news(self) -> list[NewsEvent]:
        return self._s.news.upto(self.as_of)

    def social(self, token_key: str) -> list[SocialPost]:
        s = self._s.social.get(token_key)
        return sorted(s.upto(self.as_of), key=lambda x: x.ts) if s else []

    def provider_bars(self, token_key: str) -> list[ProviderBar]:
        """Latest visible version of each (pool, bar open) pair, time-ordered."""
        s = self._s.bars.get(token_key)
        if not s:
            return []
        latest: dict[tuple[str, int], ProviderBar] = {}
        for b in s.upto(self.as_of):  # ordered by seen_ts, so later versions overwrite
            latest[(b.pool, b.ts)] = b
        return sorted(latest.values(), key=lambda b: (b.ts, b.pool))

    def coverage(self, token_key: str, kind: str) -> list[Coverage]:
        s = self._s.coverage.get(token_key)
        return [c for c in s.upto(self.as_of) if c.kind == kind] if s else []

    def has_real_market_data(self, token_key: str) -> bool:
        return token_key in self._s.bars or token_key in self._s.coverage


def _encode(d: dict) -> dict:
    out = {}
    for k, v in d.items():
        if isinstance(v, (Side, LiquidityKind)):
            out[k] = v.value
        elif isinstance(v, tuple):
            out[k] = list(v)
        else:
            out[k] = v
    return out


def decode_record(d: dict):
    d = dict(d)
    kind = d.pop("_type") if "_type" in d else d.pop("kind")  # legacy envelope used "kind"
    cls = _KINDS[kind]
    if kind == "token":
        d["ref"] = TokenRef(**d["ref"])
        d["narratives_hint"] = tuple(d.get("narratives_hint", ()))
    if kind == "swap":
        d["side"] = Side(d["side"])
    if kind == "liquidity":
        d["kind"] = LiquidityKind(d["kind"])
    for tup in ("entities", "tokens", "chains"):
        if tup in d and isinstance(d[tup], list):
            d[tup] = tuple(d[tup])
    return cls(**d)
