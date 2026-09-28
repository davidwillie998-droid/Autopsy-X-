"""Phase 5 redundancy analysis (§12/§16): pairwise dependence between the
features this phase can actually construct from real data. High
correlation is NOT automatically classified as "useless" - it is reported
alongside the CONDITIONAL question (does one still carry information after
controlling for the other), answered separately in the report by the
ablation matrix's own B-vs-C model comparison (B already contains the
return-serial features; C adds transmission on top - the incremental
effect already reported in research_ledger.py IS the conditional-information
answer for these two feature groups specifically).
"""
from __future__ import annotations

import pandas as pd

REDUNDANCY_FEATURES = ["xau_log_return", "return_autocorr", "directional_persist",
                        "reversal_frequency", "transmission_assoc_signed", "transmission_confidence"]


def classify_redundancy(abs_corr: float) -> str:
    if abs_corr >= 0.7:
        return "HIGH REDUNDANCY"
    if abs_corr >= 0.3:
        return "MODERATE REDUNDANCY"
    return "LOW REDUNDANCY"


def pairwise_redundancy(df: pd.DataFrame, features: list[str] = REDUNDANCY_FEATURES) -> pd.DataFrame:
    sub = df[features].dropna()
    pearson = sub.corr(method="pearson")
    spearman = sub.corr(method="spearman")

    rows = []
    for i, f1 in enumerate(features):
        for f2 in features[i + 1:]:
            p = float(pearson.loc[f1, f2])
            s = float(spearman.loc[f1, f2])
            rows.append({
                "feature_a": f1, "feature_b": f2, "n": len(sub),
                "pearson_corr": p, "spearman_corr": s,
                "classification": classify_redundancy(max(abs(p), abs(s))),
            })
    return pd.DataFrame(rows)
