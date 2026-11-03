"""Phase 5 baseline freeze + ablation matrix (real-data, reduced per scope.py).

MODEL DEFINITIONS (frozen here - see scope.py for why this is a REDUCED
matrix, not the full 5-layer A-E hierarchy from the authorization):

  A_baseline              : xau_log_return only (Market State, reduced to
                             the one field reconstructible from close-only
                             data - a "trivial momentum" reference point)
  B_volatility_seriality  : A + return_autocorr, directional_persist,
                             reversal_frequency (VolatilitySerialityEngine's
                             own genuinely-new return-serial metrics)
  C_transmission          : B + transmission_assoc_signed,
                             transmission_confidence (Information
                             Transmission, via lead_lag.py directly)

Regime's ATR-gated classification, CVolatilityEngine's state taxonomy, and
Shock DNA are NOT modeled here - no feature set for them exists on this
data (scope.py). They remain INSUFFICIENT EVIDENCE (real-data) in the final
report, not silently omitted.

METHOD (avoids in-sample overfitting inflating "performance" - §24/§25):
an OLS model (plain, deterministic, `numpy.linalg.lstsq`, no external ML
dependency) is fit ONLY on the DEVELOPMENT split (splits.py). Its FROZEN
coefficients are then applied to VALIDATION and OUT-OF-SAMPLE separately -
never refit, never re-selected after seeing either. Reported for each
split: Pearson IC, Spearman IC, directional accuracy (sign match rate), n.

This is explicitly INCREMENTAL PREDICTIVE INFORMATION language throughout
(§9) - nothing here is called "alpha" and no profitability claim is made
(spread/slippage/execution are not modeled at all in this module).
"""
from __future__ import annotations

from dataclasses import dataclass

import numpy as np
import pandas as pd
from scipy import stats

MODEL_FEATURES = {
    "A_baseline": ["xau_log_return"],
    "B_volatility_seriality": ["xau_log_return", "return_autocorr", "directional_persist",
                                "reversal_frequency"],
    "C_transmission": ["xau_log_return", "return_autocorr", "directional_persist",
                        "reversal_frequency", "transmission_assoc_signed", "transmission_confidence"],
}


@dataclass(frozen=True)
class FitResult:
    model: str
    target: str
    split: str
    n: int
    pearson_ic: float
    pearson_p: float
    spearman_ic: float
    spearman_p: float
    directional_accuracy: float
    coefficients: tuple[float, ...] | None = None


def _clean_xy(df: pd.DataFrame, features: list[str], target_col: str) -> tuple[np.ndarray, np.ndarray]:
    cols = features + [target_col]
    sub = df[cols].dropna()
    X = sub[features].to_numpy(dtype=float)
    y = sub[target_col].to_numpy(dtype=float)
    return X, y


def fit_ols(dev_df: pd.DataFrame, features: list[str], target_col: str) -> np.ndarray | None:
    """OLS with intercept, fit on DEV ONLY. Returns None (not a fabricated zero-
    vector model) if there are fewer usable rows than free parameters."""
    X, y = _clean_xy(dev_df, features, target_col)
    if len(y) < len(features) + 5:
        return None
    X_design = np.column_stack([np.ones(len(X)), X])
    coeffs, *_ = np.linalg.lstsq(X_design, y, rcond=None)
    return coeffs


def evaluate(df: pd.DataFrame, features: list[str], target_col: str, coeffs: np.ndarray,
             model_name: str, split_name: str) -> FitResult | None:
    X, y = _clean_xy(df, features, target_col)
    if len(y) < 5:
        return None
    X_design = np.column_stack([np.ones(len(X)), X])
    pred = X_design @ coeffs

    pear = stats.pearsonr(pred, y)
    spear = stats.spearmanr(pred, y)
    dir_acc = float(np.mean(np.sign(pred) == np.sign(y)))

    return FitResult(
        model=model_name, target=target_col, split=split_name, n=len(y),
        pearson_ic=float(pear.statistic), pearson_p=float(pear.pvalue),
        spearman_ic=float(spear.statistic), spearman_p=float(spear.pvalue),
        directional_accuracy=dir_acc, coefficients=tuple(coeffs.tolist()),
    )


def run_ablation(dev_df: pd.DataFrame, val_df: pd.DataFrame, oos_df: pd.DataFrame,
                  target_col: str, models: dict[str, list[str]] = MODEL_FEATURES) -> list[FitResult]:
    """Fits every model in `models` on DEV, evaluates on DEV/VAL/OOS. Returns a
    flat list of FitResult - one per (model, split). DEV's own result is
    included for transparency (it shows in-sample fit quality) but must never
    be quoted as the phase's evidence on its own - VAL/OOS are what matter."""
    results: list[FitResult] = []
    for name, features in models.items():
        coeffs = fit_ols(dev_df, features, target_col)
        if coeffs is None:
            continue
        for split_name, split_df in (("DEV", dev_df), ("VAL", val_df), ("OOS", oos_df)):
            r = evaluate(split_df, features, target_col, coeffs, name, split_name)
            if r is not None:
                results.append(r)
    return results


def results_to_frame(results: list[FitResult]) -> pd.DataFrame:
    return pd.DataFrame([
        {"model": r.model, "target": r.target, "split": r.split, "n": r.n,
         "pearson_ic": r.pearson_ic, "pearson_p": r.pearson_p,
         "spearman_ic": r.spearman_ic, "spearman_p": r.spearman_p,
         "directional_accuracy": r.directional_accuracy}
        for r in results
    ])
