"""
Vector autoregression (VAR) of quote changes and net order flow, and
orthogonalized impulse-response analysis - the paper's own price-impact
methodology (Hasbrouck, J. "Measuring the Information Content of Stock
Trades", Journal of Finance, 1991 - reference [9] in the source paper).

Source paper findings this module implements directly:
  - xi-xii: Hasbrouck (1991) uses a VAR model to measure price impact;
    the source paper replicates this for two stocks using TAQ data.
  - xxv-xxviii: VAR estimation preceded by a check for lag length, linear
    trend, and intercept need; a 2-equation system (quote change, net
    order flow) fit by (in the paper's case) SAS's PROC VARMAX.
  - xxix-xxx: the general form is V_t = A_1*V_{t-1} + A_2*V_{t-2} + e_t
    (a VAR of dimension k and order 2, in the paper's illustrative
    notation - their actual worked example below uses order 5).
  - xxxvi: the estimated equations, in the paper's own notation:
        x_t = a0 + sum_i(alpha^x_i * x_{t-i}) + sum_i(alpha^r_i * r_{t-i})
        r_t = g0 + g^x_t*x_t + sum_i(g^x_i * x_{t-i}) + sum_i(g^r_i * r_{t-i})
    (x = net order flow, r = return/quote change).
  - xxxvii: "we estimate 2-equation VAR model with five lags and no trend
    with OLS" - this exact worked-example specification (lags=5, trend='n')
    is offered below via a convenience function, not hardcoded as the
    only option, since the paper itself says lag length should first be
    CHECKED, not assumed.
  - xxxix: "Impulse response function decays over 12 lags... indicating
    results are well behaved" - default irf horizon here is 12 periods,
    a paper-sourced default.
  - xl-xlii: a positive net-order-flow shock raises quotes immediately
    AND in future periods (a PERSISTENT, not instantaneous, price impact)
    - this module's job is to let you check whether YOUR data reproduces
    that same qualitative finding, not to assume it will.

Uses statsmodels' VAR implementation (the open-source equivalent of the
SAS PROC VARMAX the source paper used) - results will not be numerically
identical to the paper's own SAS output even on the same data, because
the two implementations' numerical routines differ; the ECONOMETRIC
SPECIFICATION (2-equation VAR, OLS, orthogonalized IRF) is the same.
"""
from __future__ import annotations

from dataclasses import dataclass, field

import numpy as np
import pandas as pd
from statsmodels.tsa.api import VAR
from statsmodels.tsa.vector_ar.var_model import VARResultsWrapper

# Paper-sourced default (findings item xxxix).
DEFAULT_IRF_PERIODS = 12

# Paper's own worked-example specification (findings item xxxvii) - offered
# as a named convenience, not forced as the only choice, since the paper
# itself says lag length should be checked (item xxv), not assumed.
PAPER_WORKED_EXAMPLE_LAGS = 5
PAPER_WORKED_EXAMPLE_TREND = "n"  # statsmodels: 'n' = no constant, no trend


@dataclass
class VarFitResult:
    """Everything a researcher needs to read off from one VAR fit."""

    result: VARResultsWrapper
    selected_lag: int
    trend: str
    lag_selection_criterion: str
    lag_order_table: pd.DataFrame
    irf_periods: int
    variable_names: list = field(default_factory=list)

    def summary_text(self) -> str:
        return self.result.summary().as_text()

    def orthogonalized_irf(self):
        """Returns the statsmodels IRF object (has .orth_irfs, .plot(), etc.)."""
        return self.result.irf(self.irf_periods)

    def irf_dataframe(self, response: str, impulse: str) -> pd.DataFrame:
        """
        Orthogonalized impulse-response of `response` to a one-std-dev shock
        in `impulse`, as a tidy DataFrame indexed by lag (0..irf_periods).
        E.g. irf_dataframe('quote_change', 'net_order_flow') answers the
        paper's own central question: how do quotes react to an order-flow
        shock, immediately and over subsequent periods (items xl-xlii)?
        """
        irf = self.orthogonalized_irf()
        i = self.variable_names.index(impulse)
        r = self.variable_names.index(response)
        values = irf.orth_irfs[:, r, i]
        return pd.DataFrame(
            {"lag": np.arange(len(values)), "response": values}
        ).set_index("lag")


def select_lag_order(
    data: pd.DataFrame,
    maxlags: int = 15,
    criterion: str = "aic",
) -> pd.DataFrame:
    """
    "Estimation of VAR model is preceded by check for lag length" (paper
    findings item xxv). Returns statsmodels' own lag-order selection table
    (AIC/BIC/FPE/HQIC across candidate lag counts) so the researcher can
    read the tradeoff, rather than silently picking one number.
    """
    model = VAR(data)
    order_results = model.select_order(maxlags=maxlags)
    return order_results.summary()


def fit_var(
    data: pd.DataFrame,
    lags: int | None = None,
    maxlags: int = 15,
    ic: str = "aic",
    trend: str = "c",
    irf_periods: int = DEFAULT_IRF_PERIODS,
) -> VarFitResult:
    """
    Fits the 2-equation VAR(net_order_flow, quote_change) by OLS - net_order_flow
    ordered first for Cholesky/orthogonalized-IRF purposes (see the ordering
    comment where the columns are selected below).

    Parameters
    ----------
    data : DataFrame with columns ['quote_change', 'net_order_flow'], any order
        (see spreads.resample_var_inputs). Must be stationary - run
        diagnostics.check_stationarity() first; this function does not
        difference or transform the data for you.
    lags : int, optional
        Force a specific lag order. If None, selected automatically via
        `ic` (information criterion) up to `maxlags` - this is the
        "check for lag length" step the paper's own methodology requires
        (item xxv), done explicitly rather than assumed.
    maxlags, ic : passed to statsmodels' automatic lag selection when
        `lags` is None.
    trend : 'c' (constant/intercept), 'n' (none), 'ct' (constant+trend),
        'ctt' (constant+trend+trend^2) - statsmodels' own trend codes.
        Default 'c' (intercept only, no trend) is an ENGINEERING CHOICE;
        pass trend=PAPER_WORKED_EXAMPLE_TREND ('n') and
        lags=PAPER_WORKED_EXAMPLE_LAGS to replicate the paper's own
        worked-example specification (item xxxvii) instead.
    irf_periods : impulse-response horizon. Default 12 (paper finding
        item xxxix: "impulse response function decays over 12 lags").

    Returns
    -------
    VarFitResult
    """
    if set(data.columns) != {"quote_change", "net_order_flow"}:
        raise ValueError(
            "data must have exactly the columns ['quote_change','net_order_flow'] "
            "(see spreads.resample_var_inputs) - refusing to guess column order "
            "for a 2-equation VAR where equation identity matters."
        )
    # Column order here fixes the Cholesky ordering used for orthogonalized IRFs:
    # the FIRST variable can have no lag-0 (contemporaneous) response to a shock
    # in a LATER variable - only the reverse. net_order_flow is placed first so a
    # shock to it CAN move quote_change at lag 0, matching both the paper's own
    # finding ("positive net order flow causes quotes to increase immediately,
    # as well as in future periods" - item xli) and the standard Hasbrouck
    # convention that trades are contemporaneously prior to the quote revisions
    # they cause (item xxxi: "market makers post bid-ask AFTER realized
    # transaction and w.r.t. that information"). Getting this backwards doesn't
    # error - it silently forces the lag-0 order-flow-to-quote response to
    # exactly zero, which is what an earlier version of this function did.
    data = data[["net_order_flow", "quote_change"]].dropna()
    if len(data) < 50:
        raise ValueError(
            f"Only {len(data)} usable observations after dropna() - too few for a "
            "meaningful VAR fit. This is a hard refusal, not a warning: a VAR fit "
            "on a handful of points produces numbers that LOOK like a result but "
            "are not a meaningful measurement (spec section 30: never fabricate "
            "an output that looks more certain than the data supports)."
        )

    model = VAR(data)
    lag_table = model.select_order(maxlags=maxlags).summary()

    if lags is None:
        order_results = model.select_order(maxlags=maxlags)
        lags = getattr(order_results, ic)

    result = model.fit(maxlags=lags, trend=trend)

    return VarFitResult(
        result=result,
        selected_lag=lags,
        trend=trend,
        lag_selection_criterion=ic if lags is None else "manual",
        lag_order_table=lag_table,
        irf_periods=irf_periods,
        variable_names=list(data.columns),
    )


def fit_var_paper_worked_example(
    data: pd.DataFrame, irf_periods: int = DEFAULT_IRF_PERIODS
) -> VarFitResult:
    """
    Convenience wrapper reproducing the SPECIFICATION of the paper's own
    worked example (findings item xxxvii: "we estimate 2-equation VAR
    model with five lags and no trend with OLS") - the specification only,
    not the numerical result, since the paper's underlying TAQ data for
    "two stocks" is not available here.
    """
    return fit_var(
        data,
        lags=PAPER_WORKED_EXAMPLE_LAGS,
        trend=PAPER_WORKED_EXAMPLE_TREND,
        irf_periods=irf_periods,
    )
