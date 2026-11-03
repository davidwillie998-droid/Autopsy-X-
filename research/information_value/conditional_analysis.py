"""Phase 5 volatility-conditional analysis.

IMPORTANT SCOPE NOTE: regime-conditional analysis (§20 of the
authorization, "use the existing authoritative taxonomy... do not create a
new regime taxonomy") is NOT performed in this module. RegimeClassifierEngine's
real classification needs ATR (m_volRatio), which this close-only XAUUSD
dataset cannot supply (scope.py). Building any substitute trend/regime
splitter here - even an "obviously reasonable" one like a moving-average
crossover - would itself be exactly the kind of new, competing regime
taxonomy the authorization explicitly forbids. Regime-conditional analysis
therefore stays BLOCKED, same disposition as the Regime layer itself, not
worked around.

Volatility-conditional analysis (§21) IS performed, using REALIZED-VOL
TERCILES of the already-existing, already-causal `realized_vol` column
(targets.py) - this is not a new taxonomy, it is a quantile split of a
continuous measure already built for a different purpose (target
normalization), reused here descriptively. It is explicitly NOT
CVolatilityEngine's own 5-state classification (which needs ATR) and must
never be described as such.
"""
from __future__ import annotations

import numpy as np
import pandas as pd
from scipy import stats

from .permutation import block_permutation_test


def add_volatility_terciles(df: pd.DataFrame, vol_col: str = "realized_vol",
                             out_col: str = "vol_tercile") -> pd.DataFrame:
    """Tercile cut computed WITHIN the frame passed in (caller decides scope -
    e.g. call separately per split to avoid using VAL/OOS quantile boundaries
    that were not knowable during DEV). Labeled LOW/MID/HIGH."""
    out = df.copy()
    valid = out[vol_col].notna()
    out[out_col] = pd.NA
    if valid.sum() >= 30:
        out.loc[valid, out_col] = pd.qcut(out.loc[valid, vol_col], 3, labels=["LOW", "MID", "HIGH"])
    return out


def conditional_ic(df: pd.DataFrame, feature: str, target: str, tercile_col: str = "vol_tercile",
                    block_size: int = 6, n_permutations: int = 1000,
                    seed: int = 20260928) -> pd.DataFrame:
    """For each volatility tercile, block-permutation-tested Spearman IC
    between `feature` and `target`, plus the GLOBAL (unconditioned) result for
    comparison. Small buckets (n<30) are reported with n but flagged, never
    silently dropped or merged (§17: 'do not silently merge regimes')."""
    rows = []
    sub_all = df[[feature, target, tercile_col]].dropna(subset=[feature, target])

    def _one(name: str, sub: pd.DataFrame) -> dict:
        if len(sub) < 10:
            return {"bucket": name, "n": len(sub), "spearman_ic": np.nan, "naive_p": np.nan,
                    "block_perm_p": np.nan, "small_sample_warning": True}
        x = sub[feature].to_numpy(dtype=float)
        y = sub[target].to_numpy(dtype=float)
        naive = stats.spearmanr(x, y)
        perm = block_permutation_test(x, y, block_size=block_size, n_permutations=n_permutations, seed=seed)
        return {"bucket": name, "n": len(sub), "spearman_ic": float(naive.statistic),
                "naive_p": float(naive.pvalue), "block_perm_p": perm.empirical_p_value,
                "small_sample_warning": len(sub) < 30}

    rows.append(_one("GLOBAL", sub_all))
    for tercile in ("LOW", "MID", "HIGH"):
        bucket = sub_all[sub_all[tercile_col] == tercile]
        rows.append(_one(tercile, bucket))

    return pd.DataFrame(rows)
