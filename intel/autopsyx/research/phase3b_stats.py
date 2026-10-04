"""Phase 3B statistics toolkit. Pure stdlib (the project has no numpy/scipy).

Everything here is generic: it has no knowledge of hypotheses, tokens, or
Phase 3A/2 record types. The pipeline (phase3b_pipeline.py) is the only
caller, and it is the only place that decides what gets tested.
"""
from __future__ import annotations

import math
import random
from dataclasses import dataclass
from statistics import NormalDist


def _mean(xs: list[float]) -> float:
    return sum(xs) / len(xs)


def pearson(xs: list[float], ys: list[float]) -> float | None:
    """None when undefined (n<2 or zero variance in either series)."""
    n = len(xs)
    if n < 2 or n != len(ys):
        return None
    mx, my = _mean(xs), _mean(ys)
    sx = sum((x - mx) ** 2 for x in xs)
    sy = sum((y - my) ** 2 for y in ys)
    if sx == 0 or sy == 0:
        return None
    sxy = sum((x - mx) * (y - my) for x, y in zip(xs, ys))
    return sxy / math.sqrt(sx * sy)


def rank(xs: list[float]) -> list[float]:
    """Average (fractional) ranks, ties sharing the mean rank."""
    order = sorted(range(len(xs)), key=lambda i: xs[i])
    ranks = [0.0] * len(xs)
    i = 0
    while i < len(order):
        j = i
        while j + 1 < len(order) and xs[order[j + 1]] == xs[order[i]]:
            j += 1
        avg = (i + j) / 2 + 1  # 1-indexed
        for k in range(i, j + 1):
            ranks[order[k]] = avg
        i = j + 1
    return ranks


def spearman(xs: list[float], ys: list[float]) -> float | None:
    if len(xs) < 2:
        return None
    return pearson(rank(xs), rank(ys))


def min_sample_for_power(effect_r: float, alpha: float = 0.05, power: float = 0.8) -> int:
    """Sample size needed to detect a two-sided correlation of ``effect_r`` at
    the given alpha/power, via the standard Fisher-z approximation:

        n = ((z_{1-alpha/2} + z_{1-power}) / C)^2 + 3,  C = atanh(effect_r)

    z-quantiles come from the standard-library normal distribution, not a
    memorized table, so the number is reproducible from the formula alone.
    """
    z_alpha = NormalDist().inv_cdf(1 - alpha / 2)
    z_power = NormalDist().inv_cdf(power)
    c = math.atanh(effect_r)
    return math.ceil(((z_alpha + z_power) / c) ** 2 + 3)


@dataclass
class PermutationResult:
    observed_stat: float
    p_value: float
    n_permutations: int
    null_mean: float
    null_std: float


def block_permutation_test(blocks: dict[str, list[tuple[float, float]]], stat_fn=spearman,
                           n_permutations: int = 4000, seed: int = 20261001) -> PermutationResult | None:
    """Structure-preserving null for samples grouped into blocks (here: tokens).

    Within-block (x, y) pairing is never broken (the temporal dependence a
    single token's successive assessments carry stays intact); only the
    assignment of a block's y-sequence to a block's x-sequence is permuted,
    which destroys cross-token association while preserving each token's own
    autocorrelation structure. This is a block (not naive IID) permutation,
    appropriate because Phase 3A/2 assessments are overlapping, serially
    dependent observations of a handful of tokens, not independent draws.
    """
    keys = sorted(blocks)  # fixed order: determinism does not depend on dict iteration
    xs_by_key = {k: [p[0] for p in blocks[k]] for k in keys}
    ys_by_key = {k: [p[1] for p in blocks[k]] for k in keys}
    flat_x = [x for k in keys for x in xs_by_key[k]]
    flat_y = [y for k in keys for y in ys_by_key[k]]
    if len(flat_x) < 3:
        return None
    observed = stat_fn(flat_x, flat_y)
    if observed is None:
        return None
    rng = random.Random(seed)
    stats = []
    for _ in range(n_permutations):
        perm_keys = keys[:]
        rng.shuffle(perm_keys)
        py = [y for k in perm_keys for y in ys_by_key[k]]
        s = stat_fn(flat_x, py)
        if s is not None:
            stats.append(s)
    if not stats:
        return None
    extreme = sum(1 for s in stats if abs(s) >= abs(observed))
    p = (extreme + 1) / (len(stats) + 1)  # +1/+1: the observed arrangement is itself one permutation
    m = _mean(stats)
    var = sum((s - m) ** 2 for s in stats) / len(stats)
    return PermutationResult(observed, p, len(stats), m, math.sqrt(var))


def bh_fdr(pvalues: list[float]) -> list[float]:
    """Benjamini-Hochberg corrected p-values, same order as input. Monotone
    (a smaller raw p never yields a larger corrected p than a larger one)."""
    n = len(pvalues)
    if n == 0:
        return []
    order = sorted(range(n), key=lambda i: pvalues[i])
    corrected = [0.0] * n
    prev = 1.0
    for rank_i, idx in enumerate(reversed(order), start=1):
        i_from_largest = n - rank_i + 1
        val = min(prev, pvalues[idx] * n / i_from_largest)
        corrected[idx] = val
        prev = val
    return corrected


def residualize(y: list[float], z: list[float]) -> list[float]:
    """y with its best linear fit on z removed (OLS on ranks of z, since z here
    is an ordinal step index): y_i - (a + b*z_i). Used only as a transparent,
    documented approximation to a partial correlation, never as a p-value basis."""
    n = len(y)
    if n < 3:
        return list(y)
    mz, my = _mean(z), _mean(y)
    szz = sum((v - mz) ** 2 for v in z)
    if szz == 0:
        return [v - my for v in y]
    b = sum((z[i] - mz) * (y[i] - my) for i in range(n)) / szz
    a = my - b * mz
    return [y[i] - (a + b * z[i]) for i in range(n)]


def partial_spearman(x: list[float], y: list[float], z: list[float]) -> float | None:
    """Spearman correlation of x and y after each is residualized on the
    nuisance variable z (e.g. an elapsed-time/coverage proxy). A documented
    approximation (linear residualization of ranks), reported alongside the
    raw correlation, never in place of it."""
    if len(x) < 4:
        return None
    rx, ry, rz = rank(x), rank(y), rank(z)
    return pearson(residualize(rx, rz), residualize(ry, rz))


def winsorize(xs: list[float], limit: float = 0.1) -> list[float]:
    """Clip the top/bottom ``limit`` fraction to the nearest retained value."""
    n = len(xs)
    if n < 5:
        return list(xs)
    k = max(1, int(round(n * limit)))
    order = sorted(xs)
    lo, hi = order[k], order[-k - 1]
    return [min(max(x, lo), hi) for x in xs]
