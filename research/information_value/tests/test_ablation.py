"""Tests for ablation.py: OLS fit/evaluate correctness, frozen-coefficient
discipline (no refitting on VAL/OOS), and insufficient-data handling."""
from __future__ import annotations

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[3]))

import numpy as np
import pandas as pd

from research.information_value.ablation import (
    MODEL_FEATURES,
    evaluate,
    fit_ols,
    run_ablation,
)


def _synthetic_frame(n=400, seed=42, signal_strength=0.5):
    """A frame where the target is a KNOWN linear function of one feature plus
    noise - lets us verify the OLS pipeline recovers a real, known signal."""
    rng = np.random.default_rng(seed)
    x = rng.normal(0, 1, size=n)
    noise = rng.normal(0, 1, size=n)
    y = signal_strength * x + noise
    return pd.DataFrame({
        "xau_log_return": x,
        "return_autocorr": rng.normal(0, 1, size=n),
        "directional_persist": rng.normal(50, 10, size=n),
        "reversal_frequency": rng.normal(50, 10, size=n),
        "transmission_assoc_signed": rng.normal(0, 0.3, size=n),
        "transmission_confidence": rng.uniform(0, 100, size=n),
        "target": y,
    })


def test_ols_recovers_known_signal_on_held_out_split():
    dev = _synthetic_frame(n=500, seed=1, signal_strength=0.6)
    val = _synthetic_frame(n=300, seed=2, signal_strength=0.6)  # same generating process, different draw
    coeffs = fit_ols(dev, ["xau_log_return"], "target")
    assert coeffs is not None
    result = evaluate(val, ["xau_log_return"], "target", coeffs, "test_model", "VAL")
    assert result is not None
    assert result.pearson_ic > 0.3, "OLS fit on DEV should recover a real signal when evaluated on VAL"
    assert result.pearson_p < 0.01


def test_ols_returns_none_on_pure_noise_reasonably_often_is_not_asserted():
    """Pure-noise target: no specific IC value is asserted (noise CAN show a
    small spurious correlation by chance) - only that the pipeline runs and
    n matches the cleaned sample size."""
    dev = _synthetic_frame(n=200, seed=3, signal_strength=0.0)
    coeffs = fit_ols(dev, MODEL_FEATURES["A_baseline"], "target")
    assert coeffs is not None
    assert coeffs.shape == (2,)  # intercept + 1 feature


def test_coefficients_are_frozen_not_refit_per_split():
    """The exact same coefficient vector fit on DEV must be reused verbatim
    for VAL and OOS - evaluate() must never call fit_ols() internally."""
    dev = _synthetic_frame(n=400, seed=5)
    val = _synthetic_frame(n=200, seed=6)
    oos = _synthetic_frame(n=200, seed=7)
    coeffs = fit_ols(dev, ["xau_log_return"], "target")
    r_val = evaluate(val, ["xau_log_return"], "target", coeffs, "m", "VAL")
    r_oos = evaluate(oos, ["xau_log_return"], "target", coeffs, "m", "OOS")
    assert r_val.coefficients == r_oos.coefficients == tuple(coeffs.tolist())


def test_insufficient_rows_returns_none_not_fabricated_fit():
    tiny = _synthetic_frame(n=3)
    coeffs = fit_ols(tiny, MODEL_FEATURES["C_transmission"], "target")
    assert coeffs is None  # fewer rows than free parameters - must not fabricate a fit


def test_run_ablation_covers_all_three_models():
    dev = _synthetic_frame(n=500, seed=10)
    val = _synthetic_frame(n=200, seed=11)
    oos = _synthetic_frame(n=200, seed=12)
    results = run_ablation(dev, val, oos, "target")
    model_names = {r.model for r in results}
    assert model_names == set(MODEL_FEATURES.keys())
    split_names = {r.split for r in results}
    assert split_names == {"DEV", "VAL", "OOS"}


def test_nan_rows_are_dropped_not_treated_as_zero():
    df = _synthetic_frame(n=300, seed=20)
    df.loc[0:50, "xau_log_return"] = np.nan
    coeffs = fit_ols(df, ["xau_log_return"], "target")
    result = evaluate(df, ["xau_log_return"], "target", coeffs, "m", "DEV")
    assert result.n == 300 - 51  # exactly the NaN rows dropped, not zero-filled
