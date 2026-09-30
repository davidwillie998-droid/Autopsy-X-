"""Entry signal engine: fire only when independent components agree.

Output is NO_SIGNAL whenever critical information is missing. Silence is
preferable to fabricated confidence.
"""
from __future__ import annotations

from dataclasses import dataclass, field
from enum import Enum

from ..assessment import Assessment
from ..core.failure import BLOCKING, FailureMode
from ..detection.move import at_least
from ..narrative.engine import NarrativePhase
from ..news.catalyst import CatalystTiming
from ..regime.classifier import Regime
from .exhaustion import ExhaustionState


class SignalType(str, Enum):
    HIGH_CONVICTION_CONTINUATION = "HIGH_CONVICTION_CONTINUATION"
    WATCH = "WATCH"
    NO_SIGNAL = "NO_SIGNAL"


@dataclass
class Condition:
    name: str
    passed: bool | None  # None = could not be evaluated
    evidence: str
    veto: bool = False  # a failed veto condition blocks the signal outright

    def to_dict(self) -> dict:
        return dict(self.__dict__)


@dataclass
class Signal:
    type: SignalType
    token: str
    symbol: str
    chain: str
    timestamp: int
    current_price: float | None
    move_percent: float | None
    volume_acceleration: float | None
    liquidity: float | None
    wallet_growth: float | None
    news_catalyst: str
    narrative: list[str]
    manipulation_risk: float | None
    regime: str
    signal_score: float | None
    confidence: float | None
    confidence_note: str
    invalidation: dict
    risk_flags: list[str]
    conditions: list[Condition] = field(default_factory=list)
    blocked_by: list[str] = field(default_factory=list)

    def to_dict(self) -> dict:
        d = dict(self.__dict__)
        d["type"] = self.type.value
        d["conditions"] = [c.to_dict() for c in self.conditions]
        return d


def _v(o):
    return o.value if o is not None and o.ok else None


def _money(x):
    return "n/a" if x is None else f"${x:,.0f}"


def _pct(x):
    return "n/a" if x is None else f"{x:.2%}"


def evaluate_conditions(a: Assessment, cfg: dict, risk_cfg: dict, move_cfg: dict) -> list[Condition]:
    th = move_cfg["thresholds"]
    w15 = a.market.windows.get(15)
    vz = _v(w15.volume_z) if w15 else None
    va = _v(w15.volume_acceleration) if w15 else None
    lc = _v(a.liquidity.liquidity_change)
    bg, ind = _v(a.participation.buyer_growth), _v(a.participation.independence_ratio)
    cp = _v(a.participation.creator_pct)
    liq, slip = _v(a.liquidity.liquidity_usd), _v(a.liquidity.est_slippage)
    cat = a.catalyst
    phases = set(a.narrative_phases.values())

    def c(name, cond_ok, passed, evidence, veto=False):
        return Condition(name, passed if cond_ok else None, evidence, veto)

    ind_ok = (bg or 0) > 1.5 and (ind or 0) >= 0.6
    conds = [
        c("abnormal_momentum", a.move.abnormality is not None,
          a.move.direction > 0 and at_least(a.move.move_class, cfg["min_move_class"]),
          f"{a.move.move_class.value}, direction {a.move.direction}, |z| {a.move.abnormality}"),
        c("accelerating_volume", vz is not None and va is not None,
          (vz or 0) >= th["watch"] and (va or 0) > 1.0, f"15m volume z {vz}, acceleration x{va}"),
        c("expanding_liquidity", lc is not None, (lc or 0) >= 0, f"liquidity change {lc}"),
        c("independent_wallet_growth", bg is not None and ind is not None,
          (bg or 0) > 1.5 and (ind or 0) >= 0.6, f"buyer growth x{bg}, independence {ind}"),
        c("catalyst", cat.primary_event is not None,
          cat.timing in (CatalystTiming.NEWS_FIRST, CatalystTiming.SIMULTANEOUS) and cat.confirmed
          and cat.direction_consistent is not False, cat.reason),
        c("narrative_strength", bool(phases),
          bool(phases & {NarrativePhase.EMERGING.value, NarrativePhase.ACCELERATING.value}),
          f"phases {sorted(phases)}"),
        c("low_manipulation", "wash_trading" in a.manipulation.detectors_run,
          a.manipulation.score <= cfg["max_manipulation_score"],
          f"manipulation score {a.manipulation.score:.2f}", veto=True),
        c("creator_concentration_ok", cp is not None, (cp or 0) <= cfg["max_creator_pct"],
          f"creator holds {_pct(cp)}", veto=True),
        c("healthy_structure", True,
          a.exhaustion.state in (ExhaustionState.HEALTHY_EXPANSION, ExhaustionState.EXTENDED)
          and a.regime.regime not in (Regime.DEAD, Regime.COLLAPSE, Regime.DISTRIBUTION),
          f"{a.exhaustion.state.value}; regime {a.regime.regime.value}", veto=True),
        c("execution_liquidity", liq is not None and slip is not None,
          (liq or 0) >= risk_cfg["min_liquidity_usd"] and (slip or 1) <= risk_cfg["max_slippage"],
          f"liquidity {_money(liq)}, est. slippage {_pct(slip)}", veto=True),
    ]
    # Followers are never traded on the leader's move: they need their own
    # independent participation and liquidity support.
    if a.role == "FOLLOWER":
        conds.append(c("follower_independent_confirmation", bg is not None and ind is not None and lc is not None,
                       ind_ok and (lc or 0) >= 0, "follower of a leading token; own wallets and liquidity must confirm",
                       veto=True))
    return conds


def generate(a: Assessment, cfg: dict, risk_cfg: dict, move_cfg: dict) -> Signal:
    conds = evaluate_conditions(a, cfg, risk_cfg, move_cfg)
    blocked: list[str] = [f.value for f in a.failures & BLOCKING]
    if a.move_quality is None or a.move_quality.coverage < cfg["min_coverage"]:
        blocked.append(f"coverage {a.move_quality.coverage if a.move_quality else 0:.2f} < {cfg['min_coverage']}")
    for cnd in conds:
        if cnd.veto and cnd.passed is False:
            blocked.append(f"veto: {cnd.name} ({cnd.evidence})")
        if cnd.veto and cnd.passed is None:
            blocked.append(f"critical input missing: {cnd.name}")
    evaluated = [x for x in conds if x.passed is not None]
    passed = sum(1 for x in evaluated if x.passed)
    agreement = passed / len(evaluated) if evaluated else 0.0
    coverage = a.move_quality.coverage if a.move_quality else 0.0
    confidence = round(agreement * coverage, 3)

    risk_flags = sorted({f.value for f in a.failures} | {fl.kind for fl in a.manipulation.flags}
                        | set(a.exhaustion.flags))
    if not a.catalyst.confirmed and a.catalyst.primary_event is not None:
        risk_flags.append(FailureMode.NEWS_UNVERIFIED.value)
    if a.manipulation.score > cfg["max_manipulation_score"]:
        risk_flags.append(FailureMode.MANIPULATION_RISK.value)

    move_ok = a.move.direction > 0 and at_least(a.move.move_class, cfg["min_move_class"])
    if blocked:
        stype = SignalType.NO_SIGNAL
    elif not move_ok:
        watching = a.move.direction > 0 and at_least(a.move.move_class, "WATCH")
        stype = SignalType.WATCH if watching else SignalType.NO_SIGNAL
    elif passed >= cfg["min_conditions_passed"]:
        stype = SignalType.HIGH_CONVICTION_CONTINUATION
    else:
        stype = SignalType.WATCH

    w15 = a.market.windows.get(15)
    invalidation = {
        "price_below": a.move.onset_price,
        "liquidity_drop_from_entry": 0.15,
        "independence_ratio_below": 0.4,
        "creator_selling": True,
        "note": "Any one invalidates the thesis. Price level is the move's onset close.",
    }
    return Signal(
        type=stype, token=a.key, symbol=a.token.symbol, chain=a.token.ref.chain, timestamp=a.as_of,
        current_price=_v(a.market.price), move_percent=a.move.move_since_onset,
        volume_acceleration=_v(w15.volume_acceleration) if w15 else None,
        liquidity=_v(a.liquidity.liquidity_usd), wallet_growth=_v(a.participation.buyer_growth),
        news_catalyst=a.catalyst.timing.value, narrative=a.narratives,
        manipulation_risk=a.manipulation.score, regime=a.regime.regime.value,
        signal_score=a.move_quality.score if a.move_quality else None,
        confidence=confidence if stype != SignalType.NO_SIGNAL else None,
        confidence_note="agreement x coverage; uncalibrated until validated against journal outcomes",
        invalidation=invalidation, risk_flags=risk_flags, conditions=conds, blocked_by=blocked,
    )
