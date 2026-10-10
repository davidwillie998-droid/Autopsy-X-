"""Risk engine: sizes a proposed trade or refuses it, with every reason listed.

Sizing is risk-based (loss at invalidation <= budget) and then capped by
execution reality: pool share and slippage on both entry and a stressed exit.
"""
from __future__ import annotations

from dataclasses import dataclass, field

from ..features.liquidity import cpmm_slippage


@dataclass
class OpenPosition:
    token: str
    chain: str
    narratives: list[str]
    notional_usd: float


@dataclass
class PortfolioState:
    equity_usd: float
    open_positions: list[OpenPosition] = field(default_factory=list)
    realized_pnl_today_usd: float = 0.0
    consecutive_losses: int = 0


@dataclass
class TradeProposal:
    token: str
    chain: str
    narratives: list[str]
    price: float
    invalidation_price: float
    liquidity_usd: float | None
    fee_bps: float
    amm_model: str
    execution_available: bool = True


@dataclass
class RiskDecision:
    approved: bool
    notional_usd: float
    reasons: list[str]
    limits: dict

    def to_dict(self) -> dict:
        return dict(self.__dict__)


def evaluate(p: TradeProposal, pf: PortfolioState, cfg: dict) -> RiskDecision:
    refuse: list[str] = []
    notes: list[str] = []
    eq = pf.equity_usd
    limits: dict = {}

    if not p.execution_available:
        refuse.append("EXECUTION_UNAVAILABLE")
    if pf.realized_pnl_today_usd <= -cfg["max_daily_loss"] * eq:
        refuse.append(f"daily loss limit hit ({pf.realized_pnl_today_usd:,.0f})")
    if pf.consecutive_losses >= cfg["max_consecutive_losses"]:
        refuse.append(f"{pf.consecutive_losses} consecutive losses (max {cfg['max_consecutive_losses']})")
    if p.liquidity_usd is None:
        refuse.append("liquidity unobservable")
    elif p.liquidity_usd < cfg["min_liquidity_usd"]:
        refuse.append(f"LOW_LIQUIDITY: ${p.liquidity_usd:,.0f} < ${cfg['min_liquidity_usd']:,.0f}")
    if p.invalidation_price is None or p.invalidation_price >= p.price or p.invalidation_price <= 0:
        refuse.append("no valid invalidation below current price; cannot size risk")
    if refuse:
        return RiskDecision(False, 0.0, refuse, limits)

    stop_frac = 1 - p.invalidation_price / p.price
    # A stop in an illiquid token fills worse than the stop price. Budget for it.
    size_risk = cfg["max_risk_per_position"] * eq / (stop_frac + cfg["max_slippage"] * cfg["exit_slippage_multiplier"])
    limits["risk_budget_notional"] = size_risk
    limits["pool_share_cap"] = cfg["max_pool_share"] * p.liquidity_usd

    gross = sum(o.notional_usd for o in pf.open_positions)
    limits["portfolio_room"] = max(0.0, cfg["max_portfolio_exposure"] * eq - gross)
    chain_expo = sum(o.notional_usd for o in pf.open_positions if o.chain == p.chain)
    limits["chain_room"] = max(0.0, cfg["max_chain_exposure"] * eq - chain_expo)
    nar_room = cfg["max_narrative_exposure"] * eq
    for n in p.narratives:
        if n == "meme":
            continue  # universe-wide tag; narrative limits apply to specific narratives
        expo = sum(o.notional_usd for o in pf.open_positions if n in o.narratives)
        nar_room = min(nar_room, max(0.0, cfg["max_narrative_exposure"] * eq - expo))
    limits["narrative_room"] = nar_room

    caps = dict(limits)
    size = min(caps.values())
    # Shrink until entry slippage fits, then check stressed exit.
    while size > 0 and cpmm_slippage(size, p.liquidity_usd, p.fee_bps) > cfg["max_slippage"]:
        size *= 0.8
        if size < 1:
            size = 0.0
    entry_slip = cpmm_slippage(size, p.liquidity_usd, p.fee_bps) if size > 0 else None
    limits["entry_slippage"] = entry_slip
    if size <= 0:
        return RiskDecision(False, 0.0, ["HIGH_SLIPPAGE: no size fits slippage limit"], limits)
    if p.amm_model != "cpmm":
        notes.append(f"{p.amm_model} pool: slippage estimated with CPMM approximation")
    binding = "max_slippage" if size < min(caps.values()) else min(caps, key=caps.get)
    notes.append(f"binding limit: {binding}")
    if size < 10:
        return RiskDecision(False, size, ["size below minimum meaningful notional after limits"] + notes, limits)
    return RiskDecision(True, round(size, 2), notes, limits)
