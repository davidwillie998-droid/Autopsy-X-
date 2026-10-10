"""Leader / follower detection via lagged cross-correlation of bar returns.

Correlation at a positive lag says A's returns *precede* B's in this sample;
it does not say A causes B. Followers are never traded on this basis alone.
"""
from __future__ import annotations

from dataclasses import dataclass
from enum import Enum
from typing import Mapping, Sequence

from ..core.stats import pearson


class Role(str, Enum):
    LEADER = "LEADER"
    FOLLOWER = "FOLLOWER"
    LAGGARD = "LAGGARD"
    ISOLATED = "ISOLATED_MOVE"


@dataclass
class LeadLag:
    leader: str
    follower: str
    lag_bars: int
    corr: float
    contemporaneous_corr: float | None


def lagged_corr(a: Sequence[float], b: Sequence[float], lag: int) -> float | None:
    """corr(a[t], b[t + lag]). lag > 0 means a leads b."""
    if lag > 0:
        x, y = a[:-lag], b[lag:]
    elif lag < 0:
        x, y = a[-lag:], b[:lag]
    else:
        x, y = a, b
    try:
        return pearson(x, y)
    except ValueError:
        return None


def best_lag(a: Sequence[float], b: Sequence[float], max_lag: int) -> tuple[int, float] | None:
    best = None
    for lag in range(-max_lag, max_lag + 1):
        c = lagged_corr(a, b, lag)
        if c is not None and (best is None or c > best[1]):
            best = (lag, c)
    return best


def analyze(returns: Mapping[str, Sequence[float]], moving: set[str], max_lag: int,
            min_corr: float, min_advantage: float = 0.1) -> tuple[dict[str, Role], list[LeadLag]]:
    """``returns``: aligned 1-bar return series per token over the same bars.
    ``moving``: tokens currently in an abnormal up-move."""
    keys = sorted(returns)
    links: list[LeadLag] = []
    for i, a in enumerate(keys):
        for b in keys[i + 1:]:
            r = best_lag(returns[a], returns[b], max_lag)
            if r is None or r[1] < min_corr or r[0] == 0:
                continue
            lag, c = r
            c0 = lagged_corr(returns[a], returns[b], 0)
            if c0 is not None and c - c0 < min_advantage:
                continue  # lagged link not clearly stronger than same-bar co-movement (shared trend)
            lead, fol = (a, b) if lag > 0 else (b, a)
            links.append(LeadLag(lead, fol, abs(lag), c, c0))
    roles: dict[str, Role] = {}
    leads = {l.leader for l in links}
    follows = {l.follower for l in links}
    for k in keys:
        if k in leads and k not in follows:
            roles[k] = Role.LEADER
        elif k in follows:
            roles[k] = Role.FOLLOWER if k in moving else Role.LAGGARD
        else:
            roles[k] = Role.ISOLATED
    return roles, links
