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


def covered_intervals(coverage) -> list[tuple[int, int]]:
    """Merge coverage claims into disjoint [start, end) intervals."""
    out: list[list[int]] = []
    for c in sorted(coverage, key=lambda c: c.start_ts):
        if out and c.start_ts <= out[-1][1]:
            out[-1][1] = max(out[-1][1], c.end_ts)
        else:
            out.append([c.start_ts, c.end_ts])
    return [(a, b) for a, b in out]


def inside(intervals: Sequence[tuple[int, int]], lo: int, hi: int) -> bool:
    return any(a <= lo and hi <= b for a, b in intervals)


def contiguous_from(intervals: Sequence[tuple[int, int]], end: int) -> int | None:
    """Start of the covered interval that reaches ``end``; None if ``end`` is not covered."""
    for a, b in intervals:
        if a <= end <= b:
            return a
    return None


def build_bars_from_provider(pbars, swaps: Sequence[Swap], bar_cov, trade_cov, interval_ms: int,
                             start_ts: int, end_ts: int) -> list[Bar]:
    """Bars from provider OHLCV with order flow overlaid from swaps.

    Price and USD volume come from the provider bar. A minute with no provider
    bar is treated as "no trades" only when it lies inside a bars-coverage
    interval (the provider omits empty minutes); outside coverage it is marked
    incomplete. Buyers, sellers, buy/sell split and trade count are filled from
    swaps only where trade coverage spans the whole minute; elsewhere
    ``flow_known`` is False and those fields must not be read.
    """
    start = start_ts - start_ts % interval_ms
    n = max(0, (end_ts - start) // interval_ms)
    by_ts = {b.ts: b for b in pbars}
    bcov, tcov = covered_intervals(bar_cov), covered_intervals(trade_cov)
    swaps_by: dict[int, list[Swap]] = {}
    for s in swaps:
        swaps_by.setdefault(s.ts - s.ts % interval_ms, []).append(s)
    out, prev = [], None
    for i in range(n):
        t = start + i * interval_ms
        pb = by_ts.get(t)
        b = Bar(ts=t, interval_ms=interval_ms)
        if pb is not None:
            b.open, b.high, b.low, b.close = pb.open, pb.high, pb.low, pb.close
            b.volume_usd = pb.volume_usd if pb.volume_usd is not None else 0.0
            b.complete = pb.volume_usd is not None
        elif inside(bcov, t, t + interval_ms) and prev is not None:
            b.open = b.high = b.low = b.close = prev
            b.volume_usd = 0.0  # provider semantics: minute omitted = no trades
        else:
            b.complete = False
            if prev is not None:
                b.open = b.high = b.low = b.close = prev
        b.flow_known = inside(tcov, t, t + interval_ms)
        if b.flow_known:
            for s in swaps_by.get(t, []):
                b.trades += 1
                if s.side == Side.BUY:
                    b.buy_volume_usd += s.quote_usd
                    b.buyers.add(s.wallet)
                else:
                    b.sell_volume_usd += s.quote_usd
                    b.sellers.add(s.wallet)
        prev = b.close if b.close is not None else prev
        out.append(b)
    return out
