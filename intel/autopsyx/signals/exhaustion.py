"""Exhaustion detector: do not chase extreme moves blindly."""
from __future__ import annotations

from dataclasses import dataclass, field
from enum import Enum
from typing import Sequence

from ..core.models import Bar
from ..detection.move import MoveAssessment
from ..features.liquidity import LiquidityState
from ..features.market import MarketState
from ..features.participation import Participation
from ..regime.classifier import Regime, RegimeAssessment
from ..social.attention import AttentionState


class ExhaustionState(str, Enum):
    HEALTHY_EXPANSION = "HEALTHY_EXPANSION"
    EXTENDED = "EXTENDED"
    EXHAUSTION_RISK = "EXHAUSTION_RISK"
    DISTRIBUTION = "DISTRIBUTION"


@dataclass
class ExhaustionAssessment:
    state: ExhaustionState
    flags: list[str] = field(default_factory=list)

    def to_dict(self) -> dict:
        return {"state": self.state.value, "flags": self.flags}


def _v(o):
    return o.value if o is not None and o.ok else None


def upper_wick_count(bars: Sequence[Bar], n: int = 10, ratio: float = 0.6) -> int:
    """Bars where the upper wick is > ratio of the bar's range: repeated failed pushes."""
    c = 0
    for b in bars[-n:]:
        if None in (b.open, b.high, b.low, b.close) or b.high == b.low:
            continue
        if (b.high - max(b.open, b.close)) / (b.high - b.low) > ratio:
            c += 1
    return c


def assess(bars: Sequence[Bar], ms: MarketState, part: Participation, liq: LiquidityState,
           move: MoveAssessment, regime: RegimeAssessment, social: AttentionState, cfg: dict,
           parabolic_z: float, max_top10: float) -> ExhaustionAssessment:
    f: list[str] = []
    if move.direction > 0 and (move.abnormality or 0) >= parabolic_z:
        f.append(f"parabolic acceleration (|z| {move.abnormality:.1f})")
    nwv = _v(part.new_wallet_velocity)
    if nwv is not None and nwv < 1.0 and move.direction > 0:
        f.append(f"new-wallet growth decelerating (x{nwv:.2f} vs baseline)")
    t10 = _v(part.top10_pct)
    if t10 is not None and t10 > max_top10:
        f.append(f"top-10 holders own {t10:.0%}")
    lc = _v(liq.liquidity_change)
    if lc is not None and lc < -0.05:
        f.append(f"liquidity falling ({lc:.1%})")
    lh = _v(part.large_holder_net_usd)
    if lh is not None and lh < 0:
        f.append(f"large wallets net selling (${-lh:,.0f})")
    w15 = ms.windows.get(15)
    if w15 and w15.volume_z.ok and w15.volume_z.value > 6 and w15.acceleration.ok and w15.acceleration.value < 0:
        f.append("volume climax with price deceleration")
    av = _v(social.mention_velocity)
    ev = _v(social.effective_author_velocity)
    if av is not None and av > 5 and (ev is None or ev < av / 3):
        f.append(f"social frenzy (mentions x{av:.1f}) outpacing independent authors")
    slip = _v(liq.est_slippage)
    if slip is not None and slip > 0.03:
        f.append(f"slippage widening ({slip:.1%} on reference trade)")
    wicks = upper_wick_count(bars)
    if wicks >= 4:
        f.append(f"{wicks} of last 10 bars with dominant upper wicks")
    imb = _v(w15.buy_sell_imbalance) if w15 else None
    if imb is not None and imb < -0.25:
        f.append(f"abnormal sell pressure (15m imbalance {imb:.2f})")

    if regime.regime == Regime.DISTRIBUTION or Regime.DISTRIBUTION.value in regime.matched:
        state = ExhaustionState.DISTRIBUTION
    elif len(f) >= cfg["exhaustion_flags"]:
        state = ExhaustionState.EXHAUSTION_RISK
    elif len(f) >= cfg["extended_flags"]:
        state = ExhaustionState.EXTENDED
    else:
        state = ExhaustionState.HEALTHY_EXPANSION
    return ExhaustionAssessment(state, f)
