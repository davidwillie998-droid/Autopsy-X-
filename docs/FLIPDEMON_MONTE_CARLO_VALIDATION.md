# FLIPDEMON EXTREME — Monte Carlo validation protocol

## Status and safety boundary

This is an **offline, report-only research tool**. It is not imported by the MQL5 EA, does not send orders, and does not change sizing. Keep `AX_EXEC_ANALYSIS_ONLY` enabled while the EA is being validated.

The current harness resamples completed trade R-multiples. It is not yet a full market-path replay of VWAP entries/exits or adaptive pyramiding. Do not describe its output as proof of live safety or profitability.

## Research basis

- Politis & Romano (1994), *The Stationary Bootstrap*, Journal of the American Statistical Association, https://doi.org/10.1080/01621459.1994.10476870
- James & Yang (2010), *Stop-losses, maximum drawdown-at-risk and replicating financial time series with the stationary bootstrap*, Quantitative Finance, https://doi.org/10.1080/14697680903545596
- Busseti, Ryu & Boyd (2016), *Risk-Constrained Kelly Gambling*, https://web.stanford.edu/~boyd/papers/kelly.html
- Bailey & López de Prado (2014), *The Deflated Sharpe Ratio*, https://doi.org/10.3905/jpm.2014.40.5.094
- Bailey et al. (2017), *The Probability of Backtest Overfitting*, https://escholarship.org/uc/item/4w1110bb
- Sullivan, Timmermann & White, *Data-Snooping, Technical Trading Rule Performance, and the Bootstrap*, https://doi.org/10.1111/0022-1082.00163

These sources motivate dependence-aware resampling, explicit drawdown constraints, and controls for selection bias. The code is an engineering implementation inspired by these methods; it is not a replication of every paper.

## Data contract

Input is a CSV in chronological order with one row per completed trade and a numeric `r_multiple` column. Values must be net of spread, commission and slippage. Do not mix partial-close records with complete-trade outcomes unless they have been consolidated into a single, correctly weighted trade outcome. Exclude open trades. Preserve symbol and regime labels in source data for future stratified analysis.

The `--adverse-cost-r` option subtracts an additional fixed R amount from every sampled outcome. It is a sensitivity scenario, not a calibrated estimate of actual slippage. Use multiple documented stress values and do not claim they are probabilities.

## Methods

1. IID bootstrap: baseline, assumes outcomes are exchangeable/independent.
2. Stationary bootstrap: circular blocks with geometrically distributed block lengths and a configured expected length. This preserves some local serial dependence, conditional on the historical sample.
3. Fixed-fraction equity-path calculation: converts each R outcome into a percentage of current equity at risk. This is a simplified compounding model, not broker lot-size calculation.

Each method reports median, 95th and 99th percentile maximum drawdown, worst simulated drawdown, expected shortfall of the worst 5% drawdowns, final-equity percentiles, losing streaks, drawdown-threshold breach rate, and a Wilson 95% upper confidence bound for that simulated breach rate.

## Run

```bash
python -m unittest python.tests.test_monte_carlo_validation
python -m python.research.flipdemon_monte_carlo path/to/trades.csv --paths 20000 --risk-pct 0.25 --drawdown-limit-pct 8 --mean-block-length 8 --output monte_carlo_report.json
```

The tool requires at least 20 valid trades and 100 paths. A first analysis should use 20,000 or more paths and then increase the count to check numerical stability. Keep the random seed in every report.

## Interpretation guardrails

- IID vs stationary differences are diagnostic; the stationary bootstrap is not automatically correct for nonstationary or regime-shifting markets.
- A confidence interval quantifies simulation uncertainty under the chosen model, not model error or future-market certainty.
- Zero simulated breaches does not mean zero real-world risk.
- Do not infer account-currency risk, margin feasibility, stop-gap losses, or correlated multi-position exposure from trade R multiples alone.
- Do not select a risk limit after seeing the result. Pre-register thresholds and use untouched out-of-sample data.
- Record every parameter combination tested. Consider CSCV/PBO and the Deflated Sharpe Ratio if strategy parameters were selected after repeated trials.

## Next research stage

Build a separate event-driven replay harness that consumes synchronized market bars/ticks and faithfully implements the EA's actual entry, VWAP exit, stop, adaptive sizing, pyramid-addition, margin, spread and execution rules. Validate that harness against known MT5 Strategy Tester runs before relying on it. Keep this as a separate offline research module until it is independently reviewed.
