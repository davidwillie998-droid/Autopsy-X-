# AUTOPSY X — offline research engine

Implements the market-microstructure / price-impact methodology described in:

> Malhotra, Y. "Guidance to a Goldman Sachs alumnus Hedge Fund with $400B-$500B AUM:
> Alpha Trading Strategies Analysis, Maximizing Alpha for Hedge Funds, and High
> Frequency Econometrics for Analyzing Price Impact of Trades, Liquidity, and
> Market Microstructure." SSRN 3306817 (2018).

This is the `ResearchModel` referenced in the MQL5 EA's spec (section 31,
"Research vs Live Separation"). It is a standalone Python package, has no
dependency on `MQL5/`, is never imported by it, and never runs inside the
live tick loop. It exists to let a human researcher analyze historical
trade/quote data offline and, if they choose, export a few fitted
parameters as static configuration the live engine could later be pointed
at — that consumption path is not built yet (see Phase 11 in the parent
repo's task list).

## What's paper-sourced vs. engineering design

Every numeric default that traces to a specific statement in the paper is
cited in that function's docstring, module by module:

| Module | Implements |
|---|---|
| `trade_direction.py` | Lee & Ready (1991) tick test (T) and quote test (Q), 5-second quote-lag matching convention |
| `spreads.py` | Quoted/relative/effective spread, net order flow construction |
| `var_model.py` | 2-equation VAR(net_order_flow, quote_change) per Hasbrouck (1991), lag-order selection, orthogonalized impulse response (default horizon: 12 lags, matching the paper's own finding that a well-behaved response decays over that many) |
| `diagnostics.py` | Stationarity (ADF) and residual (Ljung-Box) checks, VAR stability — engineering safety steps, not paper-sourced |
| `report.py` | End-to-end pipeline tying the above together |

The paper itself does **not** provide: a LiquidityScore formula, an
AlphaScore formula, drawdown-state numeric thresholds, a crowding-proxy
formula, or any of the other MQL5-side "institutional engine" numbers.
Those live in the MQL5 codebase, explicitly labeled as engineering design
in their own comments — this package only covers the parts the paper
actually describes a testable methodology for.

## Install

```bash
pip install -r requirements.txt
```

## Run the tests

The tests use synthetic data with a **known, injected** causal relationship
(there is no real market data available in this environment) and check
that the pipeline recovers it — this validates the code is correct, not
that any particular market exhibits this relationship.

```bash
python3 tests/test_smoke.py
# or, with pytest installed:
python3 -m pytest tests/ -v
```

One test (`test_var_model_recovers_known_coefficient`) is the strict
numerical-correctness check: it caught a real bug during development
(Cholesky variable ordering silently zeroed the immediate order-flow
response when the columns were in the wrong order) and now asserts the
fitted impulse response recovers a hand-specified 0.5 coefficient to
within 0.05.

## Use it on your own data

```bash
python3 examples/run_var_analysis.py trades.csv quotes.csv report.json
```

`trades.csv` needs columns `time,price,volume`; `quotes.csv` needs
`time,bid,ask`. See `examples/run_var_analysis.py` for the programmatic
API (`autopsy_research.report.run_price_impact_analysis`).

## Honest limitations

- Not validated against the paper's own results, which used TAQ data for
  specific stocks that isn't available here — only against synthetic data
  with a known ground truth.
- `statsmodels`' `VAR` is the open-source analog of the SAS `PROC VARMAX`
  the paper used; the econometric *specification* matches, the exact
  numerical routine underneath does not, so don't expect bit-identical
  output even on identical data.
- The bid-ask spread's three cost components (order processing, inventory,
  asymmetric information — paper findings i-v) are named but not
  decomposed here; isolating each from quote/trade data alone needs a
  method the paper doesn't detail, so it's left out rather than faked.
