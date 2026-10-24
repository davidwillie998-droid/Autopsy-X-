"""Separate rankings. There is deliberately no combined "top coins" list: a
blended ranking implies a validated weighting that does not exist yet."""
from __future__ import annotations

from typing import Callable

from .assessment import Assessment
from .signals.exhaustion import ExhaustionState


def _v(o):
    return o.value if o is not None and o.ok else None


def _w(a: Assessment, n: int, attr: str):
    w = a.market.windows.get(n)
    return _v(getattr(w, attr)) if w else None


RANKINGS: dict[str, tuple[str, Callable[[Assessment], float | None]]] = {
    "BIGGEST_MOVES": ("move since onset", lambda a: a.move.move_since_onset if a.move.direction > 0 else None),
    "FASTEST_ACCELERATION": ("5-bar return acceleration", lambda a: _w(a, 5, "acceleration")),
    "BEST_MOVE_QUALITY": ("move quality score", lambda a: a.move_quality.score if a.move_quality else None),
    "STRONGEST_PARTICIPATION": ("effective buyers x buyer growth", lambda a: (
        _v(a.participation.effective_buyers) * _v(a.participation.buyer_growth)
        if _v(a.participation.effective_buyers) is not None and _v(a.participation.buyer_growth) is not None else None)),
    "STRONGEST_NARRATIVE": ("max narrative breadth", lambda a: _v(a.narrative_breadth)),
    "STRONGEST_CATALYST": ("catalyst score", lambda a: a.catalyst.score if a.catalyst.primary_event else None),
    "HIGHEST_MANIPULATION_RISK": ("manipulation score", lambda a: a.manipulation.score),
    "HIGHEST_LIQUIDITY_RISK": ("est. slippage on reference trade", lambda a: _v(a.liquidity.est_slippage)),
    "STRONGEST_CONTINUATION_STRUCTURE": ("move quality, healthy structure only", lambda a: (
        a.move_quality.score if a.move_quality and a.exhaustion.state == ExhaustionState.HEALTHY_EXPANSION
        and a.move.direction > 0 else None)),
    "EXHAUSTION_RISK": ("exhaustion flag count", lambda a: float(len(a.exhaustion.flags)) if a.move.direction > 0 else None),
}


def rank(assessments: dict[str, Assessment], name: str, limit: int = 10) -> list[dict]:
    label, fn = RANKINGS[name]
    rows = []
    for k, a in assessments.items():
        v = fn(a)
        if v is not None:
            rows.append({"token": k, "symbol": a.token.symbol, "value": v, "metric": label})
    rows.sort(key=lambda r: r["value"], reverse=True)
    return rows[:limit]


def all_rankings(assessments: dict[str, Assessment], limit: int = 10) -> dict[str, list[dict]]:
    return {n: rank(assessments, n, limit) for n in RANKINGS}
