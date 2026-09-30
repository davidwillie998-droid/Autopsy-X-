"""Price and volume abnormality relative to the coin's own history.

No fixed "+20%" definition exists here. A 20% hour is noise for a two-hour-old
token and a regime change for a two-year-old one; robust z-scores against each
coin's own baseline encode that difference.
"""
from __future__ import annotations

import math
from dataclasses import dataclass, field
from typing import Sequence

from ..core import stats
from ..core.models import Bar
from ..core.values import DataStatus, Obs, missing, ok


@dataclass
class WindowStats:
    bars: int
    ret: Obs  # log return over the window
    z: Obs  # robust z vs this coin's history of same-length windows
    percentile: Obs
    vol_adjusted: Obs  # ret / (sigma_1bar * sqrt(n))
    atr_normalized: Obs  # price change / ATR
    acceleration: Obs  # ret(last n) - ret(previous n)
    volume_usd: Obs
    volume_ratio: Obs  # volume / median historical volume for same window
    volume_z: Obs
    volume_acceleration: Obs  # volume(last n) / volume(previous n)
    trades_z: Obs
    buy_sell_imbalance: Obs  # (buy - sell) / (buy + sell), -1..1

    def to_dict(self) -> dict:
        return {k: (v.to_dict() if isinstance(v, Obs) else v) for k, v in self.__dict__.items()}


@dataclass
class MarketState:
    as_of: int
    price: Obs
    windows: dict[int, WindowStats] = field(default_factory=dict)
    market_cap: Obs = field(default_factory=lambda: missing("supply unknown"))
    volume_to_mcap_1h: Obs = field(default_factory=lambda: missing("not computed"))
    volume_to_liquidity_1h: Obs = field(default_factory=lambda: missing("not computed"))
    sigma_1bar: Obs = field(default_factory=lambda: missing("not computed"))

    def window(self, n: int) -> WindowStats | None:
        return self.windows.get(n)


def _log_ret(a: float | None, b: float | None) -> float | None:
    if a is None or b is None or a <= 0 or b <= 0:
        return None
    return math.log(b / a)


def _history(values: Sequence[float | None], n: int, end: int, count: int) -> list[float]:
    """Rolling n-sums (or n-returns via closes) ending strictly before ``end``."""
    out = []
    stride = max(1, n // 4)
    i = end - n
    while i - n >= 0 and len(out) < count:
        out.append(values[i])
        i -= stride
    return [v for v in out if v is not None]


def compute(bars: Sequence[Bar], cfg: dict, liquidity_usd: Obs | None = None,
            total_supply: float | None = None) -> MarketState:
    as_of = bars[-1].ts + bars[-1].interval_ms if bars else 0
    if not bars or bars[-1].close is None:
        return MarketState(as_of=as_of, price=missing("no bars with price"))
    closes = [b.close for b in bars]
    incomplete = any(not b.complete for b in bars[-max(cfg["windows"]) - 1:])
    price = ok(closes[-1])
    min_n = cfg["min_baseline_samples"]
    baseline = cfg["baseline_bars"]

    one_bar = [_log_ret(closes[i - 1], closes[i]) for i in range(1, len(closes))]
    one_hist = [r for r in one_bar[-baseline:] if r is not None]
    sigma = ok(stats.mad(one_hist)) if len(one_hist) >= min_n else missing(
        f"{len(one_hist)} 1-bar returns < {min_n}", DataStatus.INSUFFICIENT_HISTORY)

    trs = []
    for i in range(1, len(bars)):
        b, pc = bars[i], closes[i - 1]
        if b.high is not None and b.low is not None and pc is not None:
            trs.append(max(b.high - b.low, abs(b.high - pc), abs(b.low - pc)))
    atr = stats.mean(trs[-cfg["atr_bars"]:]) if len(trs) >= cfg["atr_bars"] else None

    vol_cum = [0.0]
    trd_cum = [0.0]
    for b in bars:
        vol_cum.append(vol_cum[-1] + b.volume_usd)
        trd_cum.append(trd_cum[-1] + b.trades)
    state = MarketState(as_of=as_of, price=price, sigma_1bar=sigma)
    L = len(bars)

    for n in cfg["windows"]:
        if L <= n:
            state.windows[n] = _empty(n, f"only {L} bars")
            continue
        r = _log_ret(closes[-1 - n], closes[-1])
        # n-window returns and volumes ending at each index, used as history
        rets_at = [None] * L
        vol_at = [None] * L
        trd_at = [None] * L
        lo = max(n, L - baseline - n)
        for j in range(lo, L):
            rets_at[j] = _log_ret(closes[j - n], closes[j])
            vol_at[j] = vol_cum[j + 1] - vol_cum[j + 1 - n]
            trd_at[j] = trd_cum[j + 1] - trd_cum[j + 1 - n]
        hist_r = _history(rets_at, n, L - 1, baseline)
        hist_v = _history(vol_at, n, L - 1, baseline)
        hist_t = _history(trd_at, n, L - 1, baseline)
        vol_n = vol_at[L - 1]
        prev_vol = vol_at[L - 1 - n] if L - 1 - n >= n else None
        prev_r = rets_at[L - 1 - n] if L - 1 - n >= n else None
        enough = len(hist_r) >= min_n
        hist_reason = f"{len(hist_r)} historical {n}-bar windows < {min_n}"

        def guarded(val: float | None, need_hist: bool = True, why: str = "") -> Obs:
            if incomplete:
                return missing("window overlaps a data gap")
            if val is None:
                return missing(why or "input missing")
            if need_hist and not enough:
                return missing(hist_reason, DataStatus.INSUFFICIENT_HISTORY)
            return ok(val)

        buy = sum(b.buy_volume_usd for b in bars[-n:])
        sell = sum(b.sell_volume_usd for b in bars[-n:])
        state.windows[n] = WindowStats(
            bars=n,
            ret=guarded(r, need_hist=False),
            z=guarded(stats.robust_z(r, hist_r) if r is not None and hist_r else None),
            percentile=guarded(stats.percentile_rank(r, hist_r) if r is not None and hist_r else None),
            vol_adjusted=guarded(r / (sigma.value * math.sqrt(n)) if r is not None and sigma.ok and sigma.value > 0 else None,
                                 why="sigma unavailable"),
            atr_normalized=guarded((closes[-1] - closes[-1 - n]) / atr if atr else None, need_hist=False,
                                   why="ATR unavailable"),
            acceleration=guarded(r - prev_r if r is not None and prev_r is not None else None, need_hist=False,
                                 why="no previous window"),
            volume_usd=guarded(vol_n, need_hist=False),
            volume_ratio=guarded(vol_n / stats.median(hist_v) if hist_v and stats.median(hist_v) > 0 else None,
                                 why="zero median historical volume"),
            volume_z=guarded(stats.robust_z(math.log1p(vol_n), [math.log1p(v) for v in hist_v]) if hist_v else None),
            volume_acceleration=guarded(vol_n / prev_vol if prev_vol else None, need_hist=False,
                                        why="no previous-window volume"),
            trades_z=guarded(stats.robust_z(trd_at[L - 1], hist_t) if hist_t else None),
            buy_sell_imbalance=guarded((buy - sell) / (buy + sell) if buy + sell > 0 else None, need_hist=False,
                                       why="no volume"),
        )

    if total_supply:
        state.market_cap = ok(closes[-1] * total_supply)
    w60 = state.windows.get(60)
    if w60 and w60.volume_usd.ok:
        if state.market_cap.ok and state.market_cap.value > 0:
            state.volume_to_mcap_1h = ok(w60.volume_usd.value / state.market_cap.value)
        if liquidity_usd is not None and liquidity_usd.ok and liquidity_usd.value > 0:
            state.volume_to_liquidity_1h = ok(w60.volume_usd.value / liquidity_usd.value)
    return state


def _empty(n: int, reason: str) -> WindowStats:
    m = missing(reason, DataStatus.INSUFFICIENT_HISTORY)
    return WindowStats(n, m, m, m, m, m, m, m, m, m, m, m, m)
