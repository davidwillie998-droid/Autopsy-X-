"""
End-to-end price-impact research pipeline: raw trades+quotes in, a
reviewable summary out. Ties together trade_direction, spreads, var_model,
and diagnostics into the sequence the source paper itself describes
(findings items xvi-xxxix): arrange trade/quote records in time order ->
classify trade direction -> compute net order flow and quote changes ->
check stationarity -> select lag order -> fit VAR -> check stability and
residuals -> compute orthogonalized impulse responses.

This module produces a JSON-serializable summary intended for a human
researcher to read, and optionally for exporting a few fitted parameters
as static configuration a live engine COULD later be pointed at - it does
not itself talk to MT5 or any live system (spec section 31: research/live
separation).
"""
from __future__ import annotations

import json
from dataclasses import asdict, dataclass
from pathlib import Path
from typing import Optional

import pandas as pd

from . import diagnostics, spreads, trade_direction, var_model


@dataclass
class PriceImpactReport:
    n_trades_raw: int
    n_trades_after_combine: int
    n_var_observations: int
    resample_freq: str
    stationarity: dict
    selected_lag: int
    trend: str
    is_stable: bool
    residual_diagnostics: dict
    irf_quote_response_to_order_flow_shock: list  # [{lag, response}, ...]
    notes: list

    def to_json(self, path: Optional[str] = None) -> str:
        payload = json.dumps(asdict(self), indent=2, default=str)
        if path:
            Path(path).write_text(payload)
        return payload


def run_price_impact_analysis(
    trades: pd.DataFrame,
    quotes: pd.DataFrame,
    resample_freq: str = "1s",
    quote_lag_seconds: float = trade_direction.DEFAULT_QUOTE_LAG_SECONDS,
    var_lags: Optional[int] = None,
    var_maxlags: int = 15,
    var_trend: str = "c",
    irf_periods: int = var_model.DEFAULT_IRF_PERIODS,
    stationarity_alpha: float = 0.05,
) -> PriceImpactReport:
    """
    Parameters
    ----------
    trades : DataFrame['time','price','volume']
    quotes : DataFrame['time','bid','ask']
    resample_freq, quote_lag_seconds, var_lags, var_maxlags, var_trend,
    irf_periods, stationarity_alpha : see the individual module docstrings
        for which of these are paper-sourced defaults vs. engineering
        choices (trade_direction.py, spreads.py, var_model.py).

    Returns
    -------
    PriceImpactReport - every field is a real computed value or an
    explicit note; nothing here is a placeholder or an assumed result.
    """
    notes: list[str] = []

    classified = trade_direction.classify_trade_direction(
        trades, quotes, quote_lag_seconds=quote_lag_seconds
    )
    n_after_combine = len(classified)

    var_input = spreads.resample_var_inputs(classified, freq=resample_freq)

    stationarity_df = diagnostics.check_stationarity(var_input, alpha=stationarity_alpha)
    non_stationary = stationarity_df[~stationarity_df["stationary_at_alpha"]]
    if len(non_stationary) > 0:
        notes.append(
            "Non-stationary series detected at alpha=%.2f: %s. VAR fit below "
            "proceeds on the LEVELS anyway (matching the paper's own stated "
            "workflow, which does not mention differencing) - treat the fitted "
            "coefficients with that caveat in mind, or difference the input "
            "yourself before calling this function."
            % (stationarity_alpha, list(non_stationary.index))
        )

    fit = var_model.fit_var(
        var_input,
        lags=var_lags,
        maxlags=var_maxlags,
        trend=var_trend,
        irf_periods=irf_periods,
    )

    stability = diagnostics.stability_check(fit)
    if not stability["is_stable"]:
        notes.append(
            "VAR is NOT stable (a companion-matrix root lies outside/on the unit "
            "circle) - impulse responses will not decay the way the paper's own "
            "finding (item xxxix) describes as 'well behaved'. Treat any IRF "
            "output from this fit as unreliable rather than a real measurement."
        )

    resid_diag = diagnostics.residual_diagnostics(fit)

    irf_df = fit.irf_dataframe("quote_change", "net_order_flow")
    irf_records = [
        {"lag": int(idx), "response": float(row["response"])}
        for idx, row in irf_df.iterrows()
    ]

    return PriceImpactReport(
        n_trades_raw=len(trades),
        n_trades_after_combine=n_after_combine,
        n_var_observations=len(var_input.dropna()),
        resample_freq=resample_freq,
        stationarity=stationarity_df.to_dict(orient="index"),
        selected_lag=fit.selected_lag,
        trend=fit.trend,
        is_stable=stability["is_stable"],
        residual_diagnostics=resid_diag.to_dict(orient="index"),
        irf_quote_response_to_order_flow_shock=irf_records,
        notes=notes,
    )
