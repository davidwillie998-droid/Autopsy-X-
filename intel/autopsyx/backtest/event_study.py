"""Event studies with matched controls.

For each event, measure forward log returns at fixed horizons from the first
price the system could have traded *after* seeing the event, and compare with
control tokens that had no such event at the same time and similar liquidity.
"""
from __future__ import annotations

import math
from dataclasses import dataclass, field
from typing import Sequence

from ..providers.store import EventStore

HORIZONS_MS = {"5m": 300_000, "15m": 900_000, "30m": 1_800_000, "1h": 3_600_000, "4h": 14_400_000,
               "12h": 43_200_000, "24h": 86_400_000}


@dataclass(frozen=True)
class StudyEvent:
    token_key: str
    seen_ts: int
    kind: str


@dataclass
class StudyResult:
    kind: str
    n_events: int
    mean_return: dict[str, float | None] = field(default_factory=dict)
    mean_control_return: dict[str, float | None] = field(default_factory=dict)
    mean_abnormal_return: dict[str, float | None] = field(default_factory=dict)
    abnormal_t_stat: dict[str, float | None] = field(default_factory=dict)
    realized_vol: dict[str, float | None] = field(default_factory=dict)


def _price_at(store: EventStore, key: str, ts: int) -> float | None:
    sw = store.view(ts).swaps(key)
    return sw[-1].price_usd if sw else None


def _liq_at(store: EventStore, key: str, ts: int) -> float | None:
    snaps = store.view(ts).pool_snapshots(key)
    return snaps[-1].liquidity_usd if snaps else None


def match_controls(store: EventStore, ev: StudyEvent, universe: Sequence[str], excluded: set[str],
                   k: int = 3) -> list[str]:
    target = _liq_at(store, ev.token_key, ev.seen_ts)
    if not target:
        return []
    cands = []
    for key in universe:
        if key == ev.token_key or key in excluded:
            continue
        liq = _liq_at(store, key, ev.seen_ts)
        if liq:
            cands.append((abs(math.log(liq / target)), key))
    return [key for _, key in sorted(cands)[:k]]


def run(store: EventStore, events: Sequence[StudyEvent], universe: Sequence[str],
        horizons: dict[str, int] = HORIZONS_MS, entry_delay_ms: int = 60_000) -> StudyResult:
    kind = events[0].kind if events else ""
    rets: dict[str, list[float]] = {h: [] for h in horizons}
    ctrl: dict[str, list[float]] = {h: [] for h in horizons}
    abn: dict[str, list[float]] = {h: [] for h in horizons}
    event_tokens_by_time = {(e.token_key, e.seen_ts // 3_600_000) for e in events}
    for ev in events:
        t0 = ev.seen_ts + entry_delay_ms
        p0 = _price_at(store, ev.token_key, t0)
        if not p0:
            continue
        excluded = {k for k, hr in event_tokens_by_time if hr == ev.seen_ts // 3_600_000}
        controls = match_controls(store, ev, universe, excluded)
        for h, dt in horizons.items():
            p1 = _price_at(store, ev.token_key, t0 + dt)
            if not p1:
                continue
            r = math.log(p1 / p0)
            rets[h].append(r)
            cr = []
            for c in controls:
                c0, c1 = _price_at(store, c, t0), _price_at(store, c, t0 + dt)
                if c0 and c1:
                    cr.append(math.log(c1 / c0))
            if cr:
                m = sum(cr) / len(cr)
                ctrl[h].append(m)
                abn[h].append(r - m)
    res = StudyResult(kind, len(events))
    for h in horizons:
        res.mean_return[h] = _mean(rets[h])
        res.mean_control_return[h] = _mean(ctrl[h])
        res.mean_abnormal_return[h] = _mean(abn[h])
        res.abnormal_t_stat[h] = _t(abn[h])
        res.realized_vol[h] = _sd(rets[h])
    return res


def _mean(xs):
    return sum(xs) / len(xs) if xs else None


def _sd(xs):
    if len(xs) < 2:
        return None
    m = sum(xs) / len(xs)
    return math.sqrt(sum((x - m) ** 2 for x in xs) / (len(xs) - 1))


def _t(xs):
    s = _sd(xs)
    return (_mean(xs) / (s / math.sqrt(len(xs)))) if s else None
