"""Liquidity state, change and execution-cost estimates."""
from __future__ import annotations

from dataclasses import dataclass
from typing import Sequence

from ..core.models import LiquidityEvent, LiquidityKind, PoolInfo, PoolSnapshot
from ..core.values import DataStatus, Obs, missing, ok


@dataclass
class LiquidityState:
    liquidity_usd: Obs
    liquidity_change: Obs  # relative change over window
    added_usd: Obs
    removed_usd: Obs
    net_flow_usd: Obs
    liquidity_to_mcap: Obs
    est_slippage: Obs  # for reference trade size, one side
    top_provider_share: Obs  # share of adds from the single largest LP wallet
    venues: int
    amm_model: str

    def to_dict(self) -> dict:
        d = {k: (v.to_dict() if isinstance(v, Obs) else v) for k, v in self.__dict__.items()}
        return d


def cpmm_slippage(trade_usd: float, liquidity_usd: float, fee_bps: float) -> float:
    """Average-price slippage for a buy against a constant-product pool.

    With quote reserve R = liquidity/2, spending d moves the average fill to
    spot * (R + d) / R, so price impact is d / R. The LP fee is added on top.
    Concentrated-liquidity pools are NOT constant-product; this is a rough
    approximation there and is labelled UNVERIFIED by the caller.
    """
    reserve = liquidity_usd / 2.0
    if reserve <= 0:
        raise ValueError("empty pool")
    return trade_usd / reserve + fee_bps / 10_000.0


def compute(snapshots: Sequence[PoolSnapshot], events: Sequence[LiquidityEvent], pools: Sequence[PoolInfo],
            as_of: int, window_ms: int, reference_trade_usd: float, market_cap: Obs) -> LiquidityState:
    start = as_of - window_ms
    snaps = [s for s in snapshots if s.ts < as_of]
    # Aggregate across pools: latest snapshot per pool.
    latest: dict[str, PoolSnapshot] = {}
    at_start: dict[str, PoolSnapshot] = {}
    for s in snaps:
        latest[s.pool] = s
        if s.ts <= start:
            at_start[s.pool] = s
    liq_now = sum(s.liquidity_usd for s in latest.values()) if latest else None
    liq_then = sum(s.liquidity_usd for s in at_start.values()) if at_start else None

    win = [e for e in events if start <= e.ts < as_of]
    added = sum(e.usd for e in win if e.kind == LiquidityKind.ADD)
    removed = sum(e.usd for e in win if e.kind == LiquidityKind.REMOVE)
    adds_by: dict[str, float] = {}
    for e in events:
        if e.ts < as_of and e.kind == LiquidityKind.ADD:
            adds_by[e.provider_wallet] = adds_by.get(e.provider_wallet, 0.0) + e.usd
    total_adds = sum(adds_by.values())

    model = pools[0].amm_model if pools else "unknown"
    fee = pools[0].fee_bps if pools else 30.0
    if liq_now:
        slip = ok(cpmm_slippage(reference_trade_usd, liq_now, fee))
        if model != "cpmm":
            slip = Obs(slip.value, DataStatus.UNVERIFIED, f"{model} pool: CPMM approximation")
    else:
        slip = missing("no liquidity observation")

    return LiquidityState(
        liquidity_usd=ok(liq_now) if liq_now is not None else missing("no pool snapshots"),
        liquidity_change=(ok(liq_now / liq_then - 1) if liq_now is not None and liq_then
                          else missing("no snapshot at window start")),
        added_usd=ok(added),
        removed_usd=ok(removed),
        net_flow_usd=ok(added - removed),
        liquidity_to_mcap=(ok(liq_now / market_cap.value) if liq_now and market_cap.ok and market_cap.value > 0
                           else missing("market cap unavailable")),
        est_slippage=slip,
        top_provider_share=ok(max(adds_by.values()) / total_adds) if total_adds > 0 else missing("no LP adds observed"),
        venues=len({p.venue for p in pools}),
        amm_model=model,
    )
