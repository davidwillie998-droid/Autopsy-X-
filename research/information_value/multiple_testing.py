"""Benjamini-Hochberg False Discovery Rate control.

Phase 5 runs many hypotheses (multiple targets x multiple models x multiple
features x multiple splits x multiple regime/volatility conditions - §16).
A handful of apparently-significant findings are EXPECTED by chance alone
at that scale. This module is the mandatory correction applied to every
p-value this phase produces before any SUPPORTED classification is made
(§21/§37 of the authorization - "do not simply select the strongest
result").
"""
from __future__ import annotations

from dataclasses import dataclass

import numpy as np


@dataclass(frozen=True)
class BHResult:
    q_values: tuple[float, ...]
    rejected: tuple[bool, ...]
    n_tests: int
    n_rejected: int
    alpha: float


def benjamini_hochberg(p_values: list[float], alpha: float = 0.05) -> BHResult:
    """Standard BH step-up procedure. NaN p-values are treated as p=1.0
    (never dropped silently - a NaN p-value means the underlying test
    couldn't be computed, which must count AGAINST significance, not be
    excluded from the correction's own denominator)."""
    p = np.array([1.0 if (v is None or v != v) else float(v) for v in p_values])
    n = len(p)
    if n == 0:
        return BHResult(q_values=(), rejected=(), n_tests=0, n_rejected=0, alpha=alpha)

    order = np.argsort(p)
    ranked_p = p[order]
    ranks = np.arange(1, n + 1)

    # BH q-value: p_(i) * n / i, then enforce monotonicity from the largest rank down
    raw_q = ranked_p * n / ranks
    q_sorted = np.minimum.accumulate(raw_q[::-1])[::-1]
    q_sorted = np.clip(q_sorted, 0.0, 1.0)

    q_values = np.empty(n)
    q_values[order] = q_sorted

    rejected = q_values <= alpha

    return BHResult(
        q_values=tuple(q_values.tolist()), rejected=tuple(bool(r) for r in rejected),
        n_tests=n, n_rejected=int(rejected.sum()), alpha=alpha,
    )
