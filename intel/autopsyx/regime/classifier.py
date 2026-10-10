"""Momentum regime classification from several dimensions, with reasons.

Rules are evaluated in priority order; the first that matches wins and every
rule that matched is recorded, so a PARABOLIC token that also shows
DISTRIBUTION evidence says so.
"""
from __future__ import annotations

import math
from dataclasses import dataclass, field
from enum import Enum
from typing import Sequence

from ..core.models import Bar
from ..detection.move import MoveAssessment
from ..features.liquidity import LiquidityState
from ..features.market import MarketState
from ..features.participation import Participation


class Regime(str, Enum):
    DEAD = "DEAD_ILLIQUID"
    COLLAPSE = "COLLAPSE"
    PARABOLIC = "PARABOLIC"
    DISTRIBUTION = "DISTRIBUTION"
    REVERSAL = "REVERSAL"
    BREAKOUT = "BREAKOUT"
    EXPANSION = "EXPANSION"
    ACCUMULATION = "ACCUMULATION"
    NEUTRAL = "NEUTRAL"
    UNKNOWN = "UNKNOWN"


@dataclass
class RegimeAssessment:
    regime: Regime
    matched: list[str] = field(default_factory=list)
    reasons: list[str] = field(default_factory=list)

    def to_dict(self) -> dict:
        return {"regime": self.regime.value, "matched": self.matched, "reasons": self.reasons}


def _v(obs):
    return obs.value if obs is not None and obs.ok else None


def classify(bars: Sequence[Bar], ms: MarketState, part: Participation, liq: LiquidityState,
             move: MoveAssessment, cfg: dict, move_cfg: dict) -> RegimeAssessment:
    if not bars or not ms.price.ok:
        return RegimeAssessment(Regime.UNKNOWN, reasons=["no price"])
    th = move_cfg["thresholds"]
    w = ms.windows
    r60, r240 = _v(w[60].ret) if 60 in w else None, _v(w[240].ret) if 240 in w else None
    z15 = _v(w[15].z) if 15 in w else None
    imb15 = _v(w[15].buy_sell_imbalance) if 15 in w else None
    vz15 = _v(w[15].volume_z) if 15 in w else None
    acc5, acc15 = (_v(w[5].acceleration) if 5 in w else None), (_v(w[15].acceleration) if 15 in w else None)
    liq_usd, liq_chg = _v(liq.liquidity_usd), _v(liq.liquidity_change)
    trades_1h = sum(b.trades for b in bars[-60:])
    hits: list[tuple[Regime, str]] = []

    if (liq_usd is not None and liq_usd < cfg["dead_min_liquidity_usd"]) or trades_1h < cfg["dead_min_trades_per_hour"]:
        hits.append((Regime.DEAD, f"liquidity {liq_usd}, trades/1h {trades_1h}"))
    if r60 is not None and r60 <= math.log(1 + cfg["collapse_return_1h"]) and (
            (liq_chg is not None and liq_chg < 0) or (imb15 is not None and imb15 < -0.2)):
        hits.append((Regime.COLLAPSE, f"1h log return {r60:.2f} with liquidity/sell-side deterioration"))
    if move.direction > 0 and (move.abnormality or 0) >= cfg["parabolic_z"] and (acc5 or 0) > 0 and (acc15 or 0) > 0:
        hits.append((Regime.PARABOLIC, f"|z|={move.abnormality:.1f} with positive 5m and 15m acceleration"))
    closes = [b.close for b in bars[-240:] if b.close is not None]
    hi240 = max(b.high for b in bars[-240:] if b.high is not None) if closes else None
    lh = _v(part.large_holder_net_usd)
    cn = _v(part.creator_net_usd)
    if hi240 and closes[-1] >= 0.9 * hi240 and imb15 is not None and imb15 < -0.1 and (
            (lh is not None and lh < 0) or (cn is not None and cn < 0)):
        hits.append((Regime.DISTRIBUTION, f"within 10% of 4h high, 15m sell imbalance {imb15:.2f}, large holders net selling"))
    if r240 is not None and r240 > 0.2 and z15 is not None and z15 <= -th["unusual"]:
        hits.append((Regime.REVERSAL, f"4h log return {r240:.2f} but 15m z {z15:.1f}"))
    rb = cfg["breakout_range_bars"]
    if len(bars) > rb + 5:
        prior_high = max(b.high for b in bars[-rb - 5:-5] if b.high is not None)
        if bars[-1].close > prior_high and vz15 is not None and vz15 >= th["watch"]:
            hits.append((Regime.BREAKOUT, f"close above {rb}-bar range high with volume z {vz15:.1f}"))
    bg = _v(part.buyer_growth)
    z60 = _v(w[60].z) if 60 in w else None
    if r60 and r60 > 0 and r240 and r240 > 0 and bg and bg > 1 and z60 is not None and z60 >= th["watch"]:
        hits.append((Regime.EXPANSION, f"1h and 4h positive, buyer growth x{bg:.2f}"))
    hg = _v(part.holder_growth)
    if z60 is not None and abs(z60) < th["watch"] and imb15 is not None and imb15 > 0.1 and (hg or 0) > 0:
        hits.append((Regime.ACCUMULATION, f"quiet price (z60 {z60:.1f}), buy imbalance {imb15:.2f}, holders rising"))

    if not hits:
        return RegimeAssessment(Regime.NEUTRAL, reasons=["no regime rule matched"])
    return RegimeAssessment(hits[0][0], [h[0].value for h in hits], [h[1] for h in hits])

