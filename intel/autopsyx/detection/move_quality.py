"""Move Quality: independent evidence for and against a move being real.

A missing component is excluded from both numerator and denominator, and the
fraction of weight that was actually observed is reported as ``coverage``.
Missing evidence never counts as neutral evidence.
"""
from __future__ import annotations

import math
from dataclasses import dataclass, field

from ..core.stats import clamp, squash
from ..core.values import Obs


@dataclass
class Component:
    name: str
    score: float | None  # 0..1, None = unavailable
    evidence: str

    def to_dict(self) -> dict:
        return dict(self.__dict__)


@dataclass
class MoveQuality:
    score: float | None  # support - penalty, range [-1, 1]
    support: float | None
    penalty: float | None
    coverage: float  # observed weight / total weight
    components: list[Component] = field(default_factory=list)
    penalties: list[Component] = field(default_factory=list)

    def to_dict(self) -> dict:
        return {
            "score": self.score, "support": self.support, "penalty": self.penalty, "coverage": self.coverage,
            "components": [c.to_dict() for c in self.components],
            "penalties": [c.to_dict() for c in self.penalties],
        }


def _c(name: str, obs_ok: bool, score_fn, evidence: str) -> Component:
    return Component(name, clamp(score_fn()) if obs_ok else None, evidence if obs_ok else f"unavailable: {evidence}")


def score(*, price_z: Obs, volume_z: Obs, buyer_growth: Obs, independence: Obs, liquidity_change: Obs,
          breadth: Obs, catalyst: Obs, cross_venue: Obs, manipulation: Obs, concentration: Obs,
          slippage: Obs, cfg: dict, max_slippage: float, significant_z: float) -> MoveQuality:
    w, p = cfg["weights"], cfg["penalties"]
    comps = [
        _c("price_momentum", price_z.ok, lambda: squash(max(price_z.value, 0), significant_z),
           f"price z={price_z.value}"),
        _c("volume_confirmation", volume_z.ok, lambda: squash(max(volume_z.value, 0), 3.0),
           f"volume z={volume_z.value}"),
        _c("wallet_participation", buyer_growth.ok and independence.ok,
           lambda: squash(max(math.log(buyer_growth.value), 0), 1.0) * independence.value,
           f"buyer growth x{buyer_growth.value}, independence {independence.value}"),
        _c("liquidity_confirmation", liquidity_change.ok, lambda: squash(max(liquidity_change.value, 0), 0.1),
           f"liquidity change {liquidity_change.value}"),
        _c("market_breadth", breadth.ok, lambda: breadth.value, f"narrative breadth {breadth.value}"),
        _c("catalyst_confirmation", catalyst.ok, lambda: catalyst.value, f"catalyst score {catalyst.value}"),
        _c("cross_venue_confirmation", cross_venue.ok, lambda: cross_venue.value,
           f"cross-venue agreement {cross_venue.value}"),
    ]
    pens = [
        _c("manipulation_risk", manipulation.ok, lambda: manipulation.value, f"manipulation {manipulation.value}"),
        _c("concentration_risk", concentration.ok, lambda: concentration.value,
           f"top-k buy share {concentration.value}"),
        _c("liquidity_risk", slippage.ok, lambda: squash(slippage.value, max_slippage),
           f"est. slippage {slippage.value}"),
    ]
    total_w = sum(w.values()) + sum(p.values())
    seen_w = sum(w[c.name] for c in comps if c.score is not None) + sum(p[c.name] for c in pens if c.score is not None)
    sw = sum(w[c.name] for c in comps if c.score is not None)
    pw = sum(p[c.name] for c in pens if c.score is not None)
    support = sum(w[c.name] * c.score for c in comps if c.score is not None) / sw if sw else None
    penalty = sum(p[c.name] * c.score for c in pens if c.score is not None) / pw if pw else None
    s = None if support is None else support - (penalty or 0.0)
    return MoveQuality(s, support, penalty, seen_w / total_w if total_w else 0.0, comps, pens)
