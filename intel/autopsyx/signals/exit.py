"""Exit intelligence: HOLD / REDUCE / EXIT / EMERGENCY_EXIT, always with reasons."""
from __future__ import annotations

from dataclasses import dataclass, field
from enum import Enum

from ..assessment import Assessment
from ..narrative.engine import NarrativePhase
from ..news.taxonomy import EventType
from ..regime.classifier import Regime
from .exhaustion import ExhaustionState


class ExitAction(str, Enum):
    HOLD = "HOLD"
    REDUCE = "REDUCE"
    EXIT = "EXIT"
    EMERGENCY_EXIT = "EMERGENCY_EXIT"


@dataclass
class Position:
    token: str
    entry_ts: int
    entry_price: float
    entry_liquidity_usd: float
    size_tokens: float
    stop_price: float | None
    narrative: list[str] = field(default_factory=list)


@dataclass
class ExitDecision:
    action: ExitAction
    reasons: list[str]

    def to_dict(self) -> dict:
        return {"action": self.action.value, "reasons": self.reasons}


def _v(o):
    return o.value if o is not None and o.ok else None


def decide(pos: Position, a: Assessment, cfg: dict, market_risk_off: bool = False) -> ExitDecision:
    emergency, exit_, reduce = [], [], []
    liq = _v(a.liquidity.liquidity_usd)
    if liq is not None and pos.entry_liquidity_usd > 0:
        drop = 1 - liq / pos.entry_liquidity_usd
        if drop >= cfg["emergency_liquidity_drop"]:
            emergency.append(f"liquidity down {drop:.0%} since entry")
        elif drop >= cfg["exit_liquidity_drop"]:
            exit_.append(f"liquidity down {drop:.0%} since entry")
    elif liq is None:
        exit_.append("liquidity unobservable; cannot verify exit capacity")
    for f in a.manipulation.flags:
        if f.kind == "creator_distribution":
            share = f.evidence.get("sell_share_of_observed_position", 0)
            (emergency if share >= cfg["creator_sell_emergency_share"] else exit_).append(
                f"creator-linked selling ({share:.0%} of observed position)")
    ev = a.catalyst.primary_event
    if ev is not None and ev.event_type in (EventType.EXPLOIT.value, EventType.DELISTING.value) and a.catalyst.confirmed:
        emergency.append(f"confirmed {ev.event_type.lower()}: {ev.headline}")
    price = _v(a.market.price)
    if price is not None and pos.stop_price is not None and price <= pos.stop_price:
        exit_.append(f"price {price:.6g} at/below invalidation {pos.stop_price:.6g}")
    if a.regime.regime in (Regime.COLLAPSE, Regime.DISTRIBUTION, Regime.DEAD):
        exit_.append(f"regime {a.regime.regime.value}")
    if a.exhaustion.state == ExhaustionState.DISTRIBUTION:
        exit_.append("distribution detected: " + "; ".join(a.exhaustion.flags[:3]))
    if a.regime.regime == Regime.REVERSAL:
        reduce.append("reversal regime (failed continuation)")
    if a.exhaustion.state == ExhaustionState.EXHAUSTION_RISK:
        reduce.append("exhaustion risk: " + "; ".join(a.exhaustion.flags[:3]))
    lh = _v(a.participation.large_holder_net_usd)
    if lh is not None and lh < 0:
        reduce.append(f"large-wallet outflow ${-lh:,.0f}")
    w15 = a.market.windows.get(15)
    if w15 and w15.volume_ratio.ok and w15.volume_ratio.value < 0.3:
        reduce.append(f"volume collapse (x{w15.volume_ratio.value:.2f} of baseline)")
    sv = _v(a.social.mention_velocity)
    if sv is not None and sv < 0.5:
        reduce.append(f"social decay (mentions x{sv:.2f} of baseline)")
    if any(p in (NarrativePhase.DECAYING.value,) for p in a.narrative_phases.values()):
        reduce.append("narrative decaying")
    if market_risk_off:
        reduce.append("market-wide risk-off")

    if emergency:
        return ExitDecision(ExitAction.EMERGENCY_EXIT, emergency + exit_ + reduce)
    if exit_:
        return ExitDecision(ExitAction.EXIT, exit_ + reduce)
    if len(reduce) >= 2:
        return ExitDecision(ExitAction.REDUCE, reduce)
    return ExitDecision(ExitAction.HOLD, reduce or ["no deterioration detected"])
