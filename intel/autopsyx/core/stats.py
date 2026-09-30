"""Deterministic statistics helpers (stdlib only, no hidden randomness)."""
from __future__ import annotations

import math
from typing import Sequence


def mean(xs: Sequence[float]) -> float:
    if not xs:
        raise ValueError("mean of empty sequence")
    return sum(xs) / len(xs)


def stdev(xs: Sequence[float]) -> float:
    if len(xs) < 2:
        raise ValueError("stdev needs >= 2 values")
    m = mean(xs)
    return math.sqrt(sum((x - m) ** 2 for x in xs) / (len(xs) - 1))


def median(xs: Sequence[float]) -> float:
    if not xs:
        raise ValueError("median of empty sequence")
    s = sorted(xs)
    n = len(s)
    mid = n // 2
    return s[mid] if n % 2 else 0.5 * (s[mid - 1] + s[mid])


def mad(xs: Sequence[float]) -> float:
    """Median absolute deviation scaled to be consistent with sigma under normality."""
    m = median(xs)
    return 1.4826 * median([abs(x - m) for x in xs])


def robust_z(x: float, history: Sequence[float], floor: float = 1e-9) -> float:
    """(x - median) / MAD. Memecoin return distributions are fat-tailed;
    mean/stdev z-scores are dominated by the last blow-off."""
    scale = mad(history)
    if scale < floor:
        # Degenerate history (e.g. constant). Fall back to stdev, then floor.
        try:
            scale = max(stdev(history), floor)
        except ValueError:
            scale = floor
    return (x - median(history)) / scale


def percentile_rank(x: float, history: Sequence[float]) -> float:
    """Fraction of history strictly below x, ties counted half. Range [0, 1]."""
    if not history:
        raise ValueError("percentile of empty history")
    below = sum(1 for h in history if h < x)
    equal = sum(1 for h in history if h == x)
    return (below + 0.5 * equal) / len(history)


def pearson(xs: Sequence[float], ys: Sequence[float]) -> float:
    n = len(xs)
    if n != len(ys) or n < 3:
        raise ValueError("pearson needs equal-length sequences of >= 3")
    mx, my = mean(xs), mean(ys)
    sxy = sum((a - mx) * (b - my) for a, b in zip(xs, ys))
    sxx = sum((a - mx) ** 2 for a in xs)
    syy = sum((b - my) ** 2 for b in ys)
    if sxx == 0 or syy == 0:
        raise ValueError("zero variance")
    return sxy / math.sqrt(sxx * syy)


def hhi(shares: Sequence[float]) -> float:
    """Herfindahl index of shares that sum to 1. 1/n = perfectly dispersed, 1 = single actor."""
    total = sum(shares)
    if total <= 0:
        raise ValueError("hhi of non-positive total")
    return sum((s / total) ** 2 for s in shares)


def noisy_or(ps: Sequence[float]) -> float:
    out = 1.0
    for p in ps:
        out *= 1.0 - max(0.0, min(1.0, p))
    return 1.0 - out


def clamp(x: float, lo: float = 0.0, hi: float = 1.0) -> float:
    return max(lo, min(hi, x))


def squash(x: float, scale: float) -> float:
    """Map [0, inf) -> [0, 1) smoothly. scale is the input giving ~0.63."""
    if x <= 0:
        return 0.0
    return 1.0 - math.exp(-x / scale)
