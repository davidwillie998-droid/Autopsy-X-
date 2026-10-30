"""Phase 5 research ledger: runs the full real-data hypothesis battery
(model-level ablation + single-feature ICs, across all 3 pre-registered
horizons, on VAL and OOS), computes a properly block-permuted p-value for
every cell (never trusts the naive parametric p-value alone - see
permutation.py's own header for why), applies Benjamini-Hochberg FDR
correction across the WHOLE battery, and classifies every hypothesis.

Every hypothesis tested is recorded here - failed ones are never deleted
(§38 of the authorization: "Never delete failed hypotheses").
"""
from __future__ import annotations

from dataclasses import dataclass, field

import numpy as np
import pandas as pd
from scipy import stats

from .ablation import MODEL_FEATURES, _clean_xy, fit_ols
from .multiple_testing import benjamini_hochberg
from .permutation import block_permutation_test
from .targets import HORIZONS

SINGLE_FEATURES = ["xau_log_return", "return_autocorr", "directional_persist",
                    "reversal_frequency", "transmission_assoc_signed", "transmission_confidence"]

BLOCK_SIZE_BY_HORIZON = {name: h + 1 for name, h in HORIZONS.items()}

N_PERMUTATIONS = 2000
PERM_SEED = 20260928


@dataclass
class LedgerRow:
    hypothesis_id: str
    kind: str  # "model" or "feature"
    name: str  # model name or feature name
    target: str
    split: str
    n: int
    statistic: str  # "spearman"
    effect_size: float
    naive_p: float
    block_perm_p: float
    q_value: float | None = None
    fdr_rejected: bool | None = None
    decision: str = "PENDING"


def _model_predictions(dev_df: pd.DataFrame, split_df: pd.DataFrame, features: list[str],
                        target_col: str) -> tuple[np.ndarray, np.ndarray] | None:
    coeffs = fit_ols(dev_df, features, target_col)
    if coeffs is None:
        return None
    X, y = _clean_xy(split_df, features, target_col)
    if len(y) < 10:
        return None
    X_design = np.column_stack([np.ones(len(X)), X])
    pred = X_design @ coeffs
    return pred, y


def _feature_values(split_df: pd.DataFrame, feature: str, target_col: str) -> tuple[np.ndarray, np.ndarray] | None:
    sub = split_df[[feature, target_col]].dropna()
    if len(sub) < 10:
        return None
    return sub[feature].to_numpy(dtype=float), sub[target_col].to_numpy(dtype=float)


def _row_id(kind: str, name: str, target: str, split: str) -> str:
    return f"{kind}:{name}:{target}:{split}"


def build_ledger(dev_df: pd.DataFrame, val_df: pd.DataFrame, oos_df: pd.DataFrame,
                  n_permutations: int = N_PERMUTATIONS) -> pd.DataFrame:
    rows: list[LedgerRow] = []

    for target_name, horizon in HORIZONS.items():
        target_col = f"fwd_ret_norm_{target_name}"
        block_size = BLOCK_SIZE_BY_HORIZON[target_name]

        for split_name, split_df in (("VAL", val_df), ("OOS", oos_df)):
            # model-level hypotheses
            for model_name, features in MODEL_FEATURES.items():
                result = _model_predictions(dev_df, split_df, features, target_col)
                if result is None:
                    continue
                pred, y = result
                naive = stats.spearmanr(pred, y)
                perm = block_permutation_test(pred, y, block_size=block_size,
                                               n_permutations=n_permutations, seed=PERM_SEED)
                rows.append(LedgerRow(
                    hypothesis_id=_row_id("model", model_name, target_col, split_name),
                    kind="model", name=model_name, target=target_col, split=split_name,
                    n=len(y), statistic="spearman", effect_size=float(naive.statistic),
                    naive_p=float(naive.pvalue), block_perm_p=perm.empirical_p_value,
                ))

            # feature-level hypotheses (§13 feature-level ablation)
            for feature in SINGLE_FEATURES:
                result = _feature_values(split_df, feature, target_col)
                if result is None:
                    continue
                x, y = result
                naive = stats.spearmanr(x, y)
                perm = block_permutation_test(x, y, block_size=block_size,
                                               n_permutations=n_permutations, seed=PERM_SEED)
                rows.append(LedgerRow(
                    hypothesis_id=_row_id("feature", feature, target_col, split_name),
                    kind="feature", name=feature, target=target_col, split=split_name,
                    n=len(y), statistic="spearman", effect_size=float(naive.statistic),
                    naive_p=float(naive.pvalue), block_perm_p=perm.empirical_p_value,
                ))

    bh = benjamini_hochberg([r.block_perm_p for r in rows], alpha=0.05)
    for row, q, rej in zip(rows, bh.q_values, bh.rejected):
        row.q_value = q
        row.fdr_rejected = rej
        row.decision = _classify(row)

    return pd.DataFrame([vars(r) for r in rows])


def _classify(row: LedgerRow) -> str:
    """SUPPORTED requires surviving FDR correction on the honest (block-
    permutation) p-value. Naive p-values are NEVER used for classification -
    only reported alongside for transparency about how much a naive analysis
    would have overstated things (see the H3/C_transmission case)."""
    if row.fdr_rejected:
        return "SUPPORTED"
    if row.block_perm_p < 0.10:
        return "PARTIALLY SUPPORTED"
    if row.n < 50:
        return "INCONCLUSIVE"
    return "NOT SUPPORTED"
