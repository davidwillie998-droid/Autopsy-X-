"""Swap stream -> fixed-interval bars.

A bar with no trades carries the previous close as its price but keeps
volume 0 and trades 0. That is a genuine observation (nobody traded) only when
the ingestor had coverage; bars inside known data gaps are marked incomplete
and every feature that touches them reports MISSING.
"""
from __future__ import annotations

from typing import Sequence

from ..core.models import Bar, Side, Swap


def build_bars(swaps: Sequence[Swap], interval_ms: int, start_ts: int, end_ts: int,
               gaps: Sequence[tuple[int, int]] = ()) -> list[Bar]:
    """Bars covering [start_ts, end_ts). ``gaps`` are (from_ts, to_ts) windows
    with no ingest coverage."""
    start = start_ts - start_ts % interval_ms
    n = max(0, (end_ts - start + interval_ms - 1) // interval_ms)
    bars = [Bar(ts=start + i * interval_ms, interval_ms=interval_ms) for i in range(n)]
    for s in swaps:
        if s.ts < start or s.ts >= start + n * interval_ms or s.price_usd <= 0:
            continue
        b = bars[(s.ts - start) // interval_ms]
        if b.open is None:
            b.open = b.high = b.low = s.price_usd
        b.high = max(b.high, s.price_usd)
        b.low = min(b.low, s.price_usd)
        b.close = s.price_usd
        b.volume_usd += s.quote_usd
        b.trades += 1
        if s.side == Side.BUY:
            b.buy_volume_usd += s.quote_usd
            b.buyers.add(s.wallet)
        else:
            b.sell_volume_usd += s.quote_usd
            b.sellers.add(s.wallet)
    prev_close = None
    for b in bars:
        if b.close is None and prev_close is not None:
            b.open = b.high = b.low = b.close = prev_close
        prev_close = b.close
        for g0, g1 in gaps:
            if b.ts < g1 and b.ts + interval_ms > g0:
                b.complete = False
    return bars
