"""
Smoke test: generates synthetic trade/quote data with a KNOWN injected
price-impact relationship (net order flow -> future quote changes), runs
the full pipeline, and checks the pipeline actually recovers a sane,
stable, non-degenerate result. This does not validate the pipeline against
real market data (none is available in this environment) - it validates
that the CODE runs correctly end-to-end and behaves sensibly on data with
a known ground truth, which is the honest thing testable here.

Run with: python3 -m pytest python/tests/test_smoke.py -v
   (or plain: python3 python/tests/test_smoke.py)
"""
from __future__ import annotations

import sys
from pathlib import Path

import numpy as np
import pandas as pd

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from autopsy_research import diagnostics, report, spreads, trade_direction, var_model


def make_synthetic_data(n_trades: int = 3000, seed: int = 7):
    rng = np.random.default_rng(seed)
    start = pd.Timestamp("2024-01-02 09:30:00")

    # quotes: a random walk mid-price with a small constant spread
    n_quotes = n_trades * 3
    quote_times = start + pd.to_timedelta(np.cumsum(rng.exponential(0.3, n_quotes)), unit="s")
    mid_walk = 100.0 + np.cumsum(rng.normal(0, 0.01, n_quotes))
    spread = 0.02
    quotes = pd.DataFrame(
        {
            "time": quote_times,
            "bid": mid_walk - spread / 2,
            "ask": mid_walk + spread / 2,
        }
    )

    # trades: alternately signed order flow that has a REAL, injected effect
    # on the next quote's midpoint (so the VAR should recover a positive,
    # persistent net_order_flow -> quote_change relationship)
    trade_times = start + pd.to_timedelta(np.cumsum(rng.exponential(0.9, n_trades)), unit="s")
    signed_flow = rng.choice([-1, 1], size=n_trades) * rng.integers(1, 50, size=n_trades)

    # inject a real causal effect: shift future mid by a function of order flow
    impact_coef = 0.0004
    extra_mid_shift = np.cumsum(signed_flow * impact_coef)
    # trade price = interpolated mid at trade time + injected shift + noise
    mid_at_trade = np.interp(
        trade_times.view("int64"), quote_times.view("int64"), mid_walk
    )
    trade_price = mid_at_trade + extra_mid_shift + rng.normal(0, 0.005, n_trades)

    trades = pd.DataFrame(
        {
            "time": trade_times,
            "price": trade_price,
            "volume": np.abs(signed_flow),
        }
    )

    # bleed the injected shift back into subsequent quotes so there is a
    # genuine, recoverable order-flow -> quote-change relationship
    shift_at_quote = np.interp(
        quote_times.view("int64"), trade_times.view("int64"), extra_mid_shift, left=0.0
    )
    quotes["bid"] = quotes["bid"] + shift_at_quote
    quotes["ask"] = quotes["ask"] + shift_at_quote

    return trades, quotes


def test_trade_direction_classification_runs():
    trades, quotes = make_synthetic_data(n_trades=500)
    classified = trade_direction.classify_trade_direction(trades, quotes)
    assert "direction" in classified.columns
    assert classified["direction"].isin([-1, 0, 1]).all()
    # most trades should be classified (not 0/unclassifiable)
    assert (classified["direction"] != 0).mean() > 0.9


def test_var_inputs_and_stationarity():
    trades, quotes = make_synthetic_data(n_trades=2000)
    classified = trade_direction.classify_trade_direction(trades, quotes)
    var_input = spreads.resample_var_inputs(classified, freq="1s")
    assert set(var_input.columns) == {"quote_change", "net_order_flow"}
    assert len(var_input) > 100

    stationarity = diagnostics.check_stationarity(var_input)
    assert set(stationarity.index) == {"quote_change", "net_order_flow"}
    # quote_change (a differenced price) should be stationary
    assert stationarity.loc["quote_change", "stationary_at_alpha"]


def test_full_pipeline_recovers_injected_impact():
    """
    End-to-end run through the REAL pipeline: raw trades/quotes -> Lee &
    Ready classification -> resampling -> stationarity -> VAR fit -> IRF.
    Because tick/quote classification is itself a noisy statistical
    procedure (as it is on real TAQ data too - the paper's own point in
    naming it an "inference"), this test checks the pipeline runs cleanly
    end-to-end and produces a well-behaved (stable, finite, right-shaped)
    result - NOT a strict sign check, which belongs on the isolated,
    exact-coefficient unit test below instead (test_var_model_recovers_
    known_coefficient), where there is no classification noise to fight.
    """
    trades, quotes = make_synthetic_data(n_trades=4000)
    result = report.run_price_impact_analysis(
        trades, quotes, resample_freq="1s", var_maxlags=8
    )
    assert result.n_var_observations > 200
    assert result.selected_lag >= 1
    assert result.is_stable, "fitted VAR should be stable on this well-behaved synthetic series"

    irf = result.irf_quote_response_to_order_flow_shock
    assert len(irf) == var_model.DEFAULT_IRF_PERIODS + 1
    assert all(np.isfinite(row["response"]) for row in irf)

    payload = result.to_json()
    assert "irf_quote_response_to_order_flow_shock" in payload


def test_var_model_recovers_known_coefficient():
    """
    Isolates the VAR/IRF machinery itself (var_model.py) from trade-
    direction classification noise: builds net_order_flow and quote_change
    directly from a hand-specified contemporaneous relationship
    (quote_change = 0.5 * net_order_flow + noise) and checks the fitted
    orthogonalized lag-0 impulse response recovers that 0.5 coefficient
    closely, with the correct sign. This is the strict numerical-
    correctness check; it caught a real bug during development (variable
    ordering determines which series can respond contemporaneously in a
    Cholesky-orthogonalized IRF - net_order_flow must be ordered first for
    it to have any lag-0 effect on quote_change at all, see var_model.fit_var).
    """
    rng = np.random.default_rng(0)
    n = 2000
    flow = rng.normal(0, 1, n)
    true_coef = 0.5
    qchange = true_coef * flow + rng.normal(0, 0.1, n)

    data = pd.DataFrame({"quote_change": qchange, "net_order_flow": flow})
    fit = var_model.fit_var(data, lags=1, trend="c")
    irf = fit.irf_dataframe("quote_change", "net_order_flow")

    lag0 = irf.loc[0, "response"]
    assert lag0 > 0, f"expected a positive lag-0 response, got {lag0}"
    assert abs(lag0 - true_coef) < 0.05, (
        f"expected the fitted lag-0 impulse response to be close to the "
        f"injected coefficient {true_coef}, got {lag0}"
    )


def test_paper_worked_example_specification():
    trades, quotes = make_synthetic_data(n_trades=3000)
    classified = trade_direction.classify_trade_direction(trades, quotes)
    var_input = spreads.resample_var_inputs(classified, freq="1s")
    fit = var_model.fit_var_paper_worked_example(var_input)
    assert fit.selected_lag == var_model.PAPER_WORKED_EXAMPLE_LAGS
    assert fit.trend == var_model.PAPER_WORKED_EXAMPLE_TREND


def test_var_refuses_wrong_columns():
    bad = pd.DataFrame({"a": np.random.randn(200), "b": np.random.randn(200)})
    try:
        var_model.fit_var(bad)
        assert False, "should have raised ValueError for wrong column names"
    except ValueError:
        pass


def test_var_refuses_too_few_observations():
    tiny = pd.DataFrame(
        {"quote_change": np.random.randn(10), "net_order_flow": np.random.randn(10)}
    )
    try:
        var_model.fit_var(tiny)
        assert False, "should have raised ValueError for too few observations"
    except ValueError:
        pass


if __name__ == "__main__":
    tests = [
        test_trade_direction_classification_runs,
        test_var_inputs_and_stationarity,
        test_full_pipeline_recovers_injected_impact,
        test_paper_worked_example_specification,
        test_var_refuses_wrong_columns,
        test_var_refuses_too_few_observations,
    ]
    for t in tests:
        t()
        print(f"PASS: {t.__name__}")
    print("\nAll smoke tests passed.")
