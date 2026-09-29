"""Phase 5 permutation/null testing - BLOCK permutation, not naive IID shuffle.

WHY NAIVE SHUFFLING IS WRONG HERE (§14/§27 of the authorization): forward
targets at horizon H (targets.py) are constructed from OVERLAPPING windows -
the H3 target at day t covers days [t, t+20], and the H3 target at day t+1
covers [t+1, t+21], sharing 19 of 20 days. Adjacent target values are
therefore heavily autocorrelated by construction, which violates the IID
assumption behind scipy's own parametric p-values (pearsonr/spearmanr) and
can make a spurious relationship look far more significant than it is - a
naive shuffle destroys this overlap structure entirely and would produce an
uninformative null (it doesn't even reproduce the target's OWN
autocorrelation under the null of "no real feature/target relationship").

BLOCK PERMUTATION (the appropriate null here): the target series is
shuffled in contiguous BLOCKS of length >= H+1 (so no permuted block
straddles the overlap window in a way that fabricates new structure),
preserving the target's own short-range serial dependence while breaking
any genuine relationship between the (fixed) model prediction and the
target's block ordering. The empirical p-value is the fraction of
permutation draws whose |statistic| meets or exceeds the observed one -
this is a fully nonparametric test that makes no IID assumption.
"""
from __future__ import annotations

from dataclasses import dataclass

import numpy as np
from scipy import stats


@dataclass(frozen=True)
class PermutationResult:
    observed_statistic: float
    n_permutations: int
    empirical_p_value: float
    null_mean: float
    null_std: float
    block_size: int


def block_permutation_test(pred: np.ndarray, target: np.ndarray, block_size: int,
                            n_permutations: int = 2000, statistic: str = "spearman",
                            seed: int = 20260928) -> PermutationResult:
    """`pred` is held fixed (it is a frozen model output - see ablation.py's own
    "coefficients frozen, never refit" discipline). `target` is permuted in
    contiguous blocks of `block_size`. Uses a fresh, explicitly-seeded RNG
    (not a shared module-level one - the exact bug class caught and fixed in
    Phase 4A's own test suite: a shared RNG makes results depend on call
    order)."""
    n = len(pred)
    assert len(target) == n
    rng = np.random.default_rng(seed)

    stat_fn = stats.spearmanr if statistic == "spearman" else stats.pearsonr
    observed = float(stat_fn(pred, target).statistic)

    n_blocks = int(np.ceil(n / block_size))
    # pad target index list to a whole number of blocks by repeating the tail block's
    # own indices (never fabricates new DATA VALUES - only reuses existing target rows
    # so the permuted array is always drawn from real observations)
    block_starts = list(range(0, n, block_size))

    null_stats = np.empty(n_permutations)
    for p in range(n_permutations):
        order = rng.permutation(len(block_starts))
        permuted_idx = []
        for b in order:
            start = block_starts[b]
            end = min(start + block_size, n)
            permuted_idx.extend(range(start, end))
        permuted_idx = np.array(permuted_idx[:n])
        permuted_target = target[permuted_idx]
        null_stats[p] = stat_fn(pred, permuted_target).statistic

    empirical_p = float(np.mean(np.abs(null_stats) >= np.abs(observed)))

    return PermutationResult(
        observed_statistic=observed, n_permutations=n_permutations,
        empirical_p_value=empirical_p, null_mean=float(null_stats.mean()),
        null_std=float(null_stats.std()), block_size=block_size,
    )
