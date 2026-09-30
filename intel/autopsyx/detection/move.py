"""Big-move detection: how abnormal is the move, and when did it start."""
from __future__ import annotations

import math
from dataclasses import dataclass
from enum import Enum
from typing import Sequence

from ..core.models import Bar
from ..features.market import MarketState


class MoveClass(str, Enum):
    UNCLASSIFIED = "UNCLASSIFIED"  # not enough history to judge abnormality
    NORMAL = "NORMAL"
    WATCH = "WATCH"
    UNUSUAL = "UNUSUAL"
    SIGNIFICANT = "SIGNIFICANT"
    EXTREME = "EXTREME"


ORDER = [MoveClass.UNCLASSIFIED, MoveClass.NORMAL, MoveClass.WATCH, MoveClass.UNUSUAL,
         MoveClass.SIGNIFICANT, MoveClass.EXTREME]


def at_least(c: MoveClass, floor: MoveClass | str) -> bool:
    return ORDER.index(c) >= ORDER.index(MoveClass(floor))


@dataclass
class MoveAssessment:
    move_class: MoveClass
    direction: int  # +1 up, -1 down, 0 none
    abnormality: float | None  # max |robust z| across windows
    driving_window: int | None  # window (bars) with the largest |z|
    window_z: dict[int, float]
    onset_ts: int | None
    onset_price: float | None
    move_since_onset: float | None  # simple return from onset close to now
    volume_only_anomaly: bool
    reason: str = ""

    def to_dict(self) -> dict:
        d = dict(self.__dict__)
        d["move_class"] = self.move_class.value
        return d


def classify(state: MarketState, bars: Sequence[Bar], cfg: dict, onset_lookback: int = 240) -> MoveAssessment:
    th = cfg["thresholds"]
    zs = {n: w.z.value for n, w in state.windows.items() if w.z.ok}
    vz = [w.volume_z.value for w in state.windows.values() if w.volume_z.ok]
    if not zs:
        return MoveAssessment(MoveClass.UNCLASSIFIED, 0, None, None, {}, None, None, None, False,
                              "no window has enough history for a robust z-score")
    n_star = max(zs, key=lambda n: abs(zs[n]))
    a = abs(zs[n_star])
    if a >= th["extreme"]:
        c = MoveClass.EXTREME
    elif a >= th["significant"]:
        c = MoveClass.SIGNIFICANT
    elif a >= th["unusual"]:
        c = MoveClass.UNUSUAL
    elif a >= th["watch"]:
        c = MoveClass.WATCH
    else:
        c = MoveClass.NORMAL
    direction = 0 if c == MoveClass.NORMAL else (1 if zs[n_star] > 0 else -1)
    onset_ts = onset_px = since = None
    if direction and state.sigma_1bar.ok:
        idx = find_onset(bars, state.sigma_1bar.value, direction, onset_lookback)
        if idx is not None:
            onset_ts, onset_px = bars[idx].ts + bars[idx].interval_ms, bars[idx].close
            since = bars[-1].close / onset_px - 1 if onset_px else None
    vol_only = c in (MoveClass.NORMAL, MoveClass.WATCH) and bool(vz) and max(vz) >= th["significant"]
    return MoveAssessment(c, direction, a, n_star, zs, onset_ts, onset_px, since, vol_only)


def find_onset(bars: Sequence[Bar], sigma: float, direction: int, lookback: int) -> int | None:
    """Index of the bar where the current run most plausibly began.

    Picks t maximising direction * log(close_now / close_t) / (sigma * sqrt(now - t)):
    the start point that makes the move most statistically significant. Uses
    only bars up to now, so it is safe inside a backtest.
    """
    if sigma <= 0 or len(bars) < 2 or bars[-1].close is None:
        return None
    now = len(bars) - 1
    best, best_i = 0.0, None
    for t in range(max(0, now - lookback), now):
        c = bars[t].close
        if c is None or c <= 0:
            continue
        score = direction * math.log(bars[now].close / c) / (sigma * math.sqrt(now - t))
        if score > best:
            best, best_i = score, t
    return best_i
