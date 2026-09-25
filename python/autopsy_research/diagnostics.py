"""
Stationarity and residual diagnostics for the VAR model.

Not sourced from specific paper statements - a VAR fit on non-stationary
data or with pathological residuals produces coefficients that are not
meaningful, so these checks are ENGINEERING SAFETY steps (spec section 30:
"never fabricate an output that looks more certain than the data
supports"), run before trusting fit_var()'s output.
"""
from __future__ import annotations

import numpy as np
import pandas as pd
from statsmodels.stats.diagnostic import acorr_ljungbox
from statsmodels.tsa.stattools import adfuller


def check_stationarity(
    data: pd.DataFrame, alpha: float = 0.05
) -> pd.DataFrame:
    """
    Augmented Dickey-Fuller test per column. Returns a DataFrame with the
    test statistic, p-value, and a plain-language verdict per series.

    A p-value below `alpha` rejects the null of a unit root (series is
    stationary). This function does NOT auto-difference non-stationary
    series - that decision belongs to the researcher, since differencing
    changes what the VAR coefficients mean.
    """
    rows = []
    for col in data.columns:
        series = data[col].dropna()
        # result_object=False pins the plain-tuple return shape explicitly rather
        # than relying on today's default, which statsmodels has flagged as
        # changing in a future release - avoids this breaking silently later.
        stat, pvalue, used_lag, nobs, crit_values, _ = adfuller(
            series, autolag="AIC", result_object=False
        )
        rows.append(
            {
                "series": col,
                "adf_statistic": stat,
                "p_value": pvalue,
                "n_obs": nobs,
                "used_lag": used_lag,
                "stationary_at_alpha": bool(pvalue < alpha),
            }
        )
    return pd.DataFrame(rows).set_index("series")


def residual_diagnostics(fit_result, lags: int = 10) -> pd.DataFrame:
    """
    Ljung-Box test for residual autocorrelation, per equation, on a fitted
    VarFitResult (see var_model.fit_var). A well-specified VAR should leave
    residuals close to white noise - large Ljung-Box statistics (low
    p-values) suggest the chosen lag order under-fits the true dynamics.

    Parameters
    ----------
    fit_result : var_model.VarFitResult
    lags : number of autocorrelation lags to test.
    """
    resid = fit_result.result.resid
    rows = []
    for col in resid.columns:
        lb = acorr_ljungbox(resid[col], lags=[lags], return_df=True)
        rows.append(
            {
                "equation": col,
                "ljung_box_stat": float(lb["lb_stat"].iloc[0]),
                "p_value": float(lb["lb_pvalue"].iloc[0]),
                "residuals_look_like_white_noise": bool(lb["lb_pvalue"].iloc[0] > 0.05),
            }
        )
    return pd.DataFrame(rows).set_index("equation")


def stability_check(fit_result) -> dict:
    """
    A VAR is stable (impulse responses eventually decay, matching the
    paper's own "well behaved" description in findings item xxxix) iff all
    eigenvalues of the companion matrix lie inside the unit circle.
    statsmodels exposes this directly via VARResults.is_stable().
    """
    is_stable = fit_result.result.is_stable()
    roots = fit_result.result.roots
    return {
        "is_stable": bool(is_stable),
        "roots": roots.tolist() if hasattr(roots, "tolist") else list(roots),
        "min_abs_root": float(np.min(np.abs(roots))) if len(roots) else None,
    }
