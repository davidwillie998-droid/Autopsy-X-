"""Tests for research_ledger.py's ledger-construction and classification
logic. Uses small synthetic data and a low permutation count for speed -
the real, full-scale ledger run is a separate, documented, one-time
research artifact (docs/PHASE5_INFORMATION_VALUE_REPORT.md), not something
re-executed on every test run."""
from __future__ import annotations

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[3]))

import numpy as np
import pandas as pd

from research.information_value.research_ledger import build_ledger, _classify, LedgerRow


def _synthetic_full_frame(n=400, seed=1, signal=0.0):
    rng = np.random.default_rng(seed)
    x = rng.normal(0, 1, n)
    df = pd.DataFrame({
        "xau_log_return": x,
        "return_autocorr": rng.normal(0, 1, n),
        "directional_persist": rng.normal(50, 10, n),
        "reversal_frequency": rng.normal(50, 10, n),
        "transmission_assoc_signed": rng.normal(0, 0.3, n),
        "transmission_confidence": rng.uniform(0, 100, n),
    })
    for name in ("H1", "H2", "H3"):
        noise = rng.normal(0, 1, n)
        df[f"fwd_ret_norm_{name}"] = signal * x + noise
    return df


def test_ledger_never_drops_failed_hypotheses():
    """Every (model/feature, target, split) combination attempted must appear
    in the output - §38: 'never delete failed hypotheses'."""
    dev = _synthetic_full_frame(n=300, seed=1, signal=0.0)
    val = _synthetic_full_frame(n=150, seed=2, signal=0.0)
    oos = _synthetic_full_frame(n=150, seed=3, signal=0.0)
    ledger = build_ledger(dev, val, oos, n_permutations=100)
    # 3 models + 6 features = 9 hypotheses per (target, split); 3 targets * 2 splits = 6
    assert len(ledger) == 9 * 6
    assert set(ledger["decision"]) <= {"SUPPORTED", "PARTIALLY SUPPORTED", "INCONCLUSIVE", "NOT SUPPORTED"}


def test_genuine_strong_signal_can_reach_supported():
    dev = _synthetic_full_frame(n=600, seed=10, signal=3.0)
    val = _synthetic_full_frame(n=400, seed=11, signal=3.0)
    oos = _synthetic_full_frame(n=400, seed=12, signal=3.0)
    ledger = build_ledger(dev, val, oos, n_permutations=200)
    assert (ledger["decision"] == "SUPPORTED").any(), "a strong, real, repeated signal should survive FDR"


def test_pure_noise_rarely_reaches_supported():
    dev = _synthetic_full_frame(n=400, seed=20, signal=0.0)
    val = _synthetic_full_frame(n=250, seed=21, signal=0.0)
    oos = _synthetic_full_frame(n=250, seed=22, signal=0.0)
    ledger = build_ledger(dev, val, oos, n_permutations=200)
    n_supported = (ledger["decision"] == "SUPPORTED").sum()
    assert n_supported <= 1, f"pure noise should rarely survive FDR correction, got {n_supported}"


def test_classify_supported_requires_fdr_rejection():
    row = LedgerRow(hypothesis_id="x", kind="model", name="m", target="t", split="VAL",
                     n=100, statistic="spearman", effect_size=0.5, naive_p=0.001,
                     block_perm_p=0.001, q_value=0.01, fdr_rejected=True)
    assert _classify(row) == "SUPPORTED"


def test_classify_not_supported_high_p_large_n():
    row = LedgerRow(hypothesis_id="x", kind="model", name="m", target="t", split="VAL",
                     n=500, statistic="spearman", effect_size=0.01, naive_p=0.9,
                     block_perm_p=0.9, q_value=0.95, fdr_rejected=False)
    assert _classify(row) == "NOT SUPPORTED"


def test_classify_inconclusive_small_n():
    row = LedgerRow(hypothesis_id="x", kind="feature", name="f", target="t", split="VAL",
                     n=20, statistic="spearman", effect_size=0.3, naive_p=0.3,
                     block_perm_p=0.3, q_value=0.6, fdr_rejected=False)
    assert _classify(row) == "INCONCLUSIVE"


def test_ledger_columns_include_both_naive_and_block_permutation_p():
    """Both must be reported side by side - the divergence between them IS
    part of the evidence (see the H3/C_transmission finding)."""
    dev = _synthetic_full_frame(n=200, seed=30)
    val = _synthetic_full_frame(n=100, seed=31)
    oos = _synthetic_full_frame(n=100, seed=32)
    ledger = build_ledger(dev, val, oos, n_permutations=50)
    assert "naive_p" in ledger.columns
    assert "block_perm_p" in ledger.columns
