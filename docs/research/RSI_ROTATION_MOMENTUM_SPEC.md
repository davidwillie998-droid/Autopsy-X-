# RSI Rotation Momentum — Research Specification

**Project:** FlipDemon Extreme HFT  
**Status:** Research-only specification; not approved for execution  
**Initial signal timeframe:** M15  
**Context timeframes:** H1 and H4  
**Initial RSI period:** 14  
**Execution authority:** None

## 1. Objective

Rank an eligible instrument universe by relative strength and momentum persistence. The module is an opportunity-ranking and observation component. It must not submit orders, modify position size, change risk limits, or authorize pyramiding.

The hypothesis is that instruments with persistent relative outperformance and improving momentum may offer better directional opportunities than instruments selected by RSI thresholds alone. This is a testable hypothesis, not an assumed edge.

## 2. Scope and market-family separation

Do not pool equities, FX, metals, crypto, and synthetic indices into one unqualified ranking. Maintain separate universes and benchmarks. A cross-family comparison is permitted only after explicit normalization and separate validation.

For every instrument, record broker/provider, symbol, market family, quote currency, timeframe, session calendar, point/tick conventions, data source, and data-quality status. Exclude instruments with insufficient history, stale bars, invalid OHLC values, or unresolved symbol identity.

## 3. Data contract

Input is timestamped OHLCV bars. Required fields:

- timestamp (UTC, ISO-8601 or Unix seconds)
- symbol
- open, high, low, close
- volume (optional for initial price-only score; missing volume must be explicit)

Requirements:

- Use completed candles only. A bar is eligible only after its close time.
- Sort by timestamp and reject duplicate symbol/timestamp rows.
- Require finite positive OHLC values and high >= max(open, close), low <= min(open, close).
- Do not forward-fill missing prices or silently bridge market closures.
- Preserve raw source data and a data manifest.
- Apply corporate-action adjustments consistently for equities.
- Prevent survivorship bias in historical universes; record historical membership where available.
- Use UTC timestamps internally and explicit exchange/broker calendars for session handling.

## 4. Initial feature definitions

Calculate features independently per instrument:

1. RSI(14), Wilder smoothing, on completed M15 closes.
2. Momentum returns over 4, 16, and 48 completed M15 bars.
3. Relative return versus the relevant family benchmark over the same horizons.
4. H1 and H4 trend alignment, calculated only from fully completed higher-timeframe bars.
5. Volatility normalization using a rolling ATR(14) or realized volatility estimate.

Do not treat RSI > 70 as an automatic buy or RSI < 30 as an automatic sell. RSI is a regime/momentum descriptor, not a standalone entry instruction.

## 5. Initial ranking score — hypothesis, not optimized truth

Initial weights for the first baseline experiment:

- Relative performance composite: 35%
- Momentum consistency: 30%
- RSI regime and direction: 20%
- H1/H4 trend alignment: 15%

Use cross-sectional percentile ranks within each eligible market-family universe. Convert each component to a bounded comparable scale before combining. If any required component is missing, return NO_RANK rather than silently redistributing weights.

Record both the raw components and final score. Keep an equal-weight score and simple 16-bar relative-return ranking as baselines. Do not tune weights on the final test period.

## 6. Output schema

Each instrument observation must include:

- timestamp, symbol, market_family, benchmark
- rsi_14, return_4, return_16, return_48
- relative_return_4, relative_return_16, relative_return_48
- momentum_consistency, h1_alignment, h4_alignment
- component_percentiles, composite_score, cross_sectional_rank
- state: LEADING | STRENGTHENING | WEAKENING | LAGGING | NO_RANK
- data_quality_flags, rejection_reason
- strategy_version, data_version

This output is diagnostic only. No order, lot, stop, target, or risk fields are permitted in this module's interface.

## 7. Leakage and reproducibility controls

- Features at time t may use only data available by the close of t.
- Benchmark returns must use matching timestamps and calendars.
- Higher-timeframe features must use the last fully completed H1/H4 bar.
- Cross-sectional ranks must use only instruments eligible at that timestamp.
- Fit normalization parameters on training data only; freeze them for validation/test.
- Record input file hashes, code commit, configuration, timezone, universe membership, and run timestamp.
- Identical inputs, code, and configuration must produce identical outputs.

## 8. Research protocol

1. Validate data completeness, timestamp alignment, and universe membership.
2. Establish baselines: buy-and-hold benchmark, simple 16-bar momentum rank, and equal-weight composite.
3. Evaluate forward returns at 4, 16, and 48 M15 bars, clearly labelled as research outcomes, not executable returns.
4. Include realistic spread, commission, slippage, financing and turnover assumptions before any tradable simulation.
5. Use chronological train/validation/test splits and walk-forward evaluation.
6. Report results by instrument, market family, volatility regime, trend regime, and calendar period.
7. Run ablations to determine whether RSI, relative strength, or higher-timeframe alignment adds incremental value.
8. Preserve failed and null results. Do not select only profitable symbols or periods after seeing outcomes.

## 9. Metrics and acceptance gates

Report observation count, eligible universe size, coverage, rank stability, forward-return distribution, rank monotonicity, top-minus-bottom spread, turnover, cost-adjusted expectancy, profit factor where trade construction is defined, maximum drawdown, and confidence intervals.

A research pass requires:
- no detected look-ahead leakage;
- reproducible outputs and data manifest;
- sufficient observations and universe coverage;
- positive, economically meaningful out-of-sample rank spread after conservative costs;
- stability across multiple chronological folds and relevant regimes;
- incremental value over the simple momentum baseline.

If these conditions are not met, verdict is NOT APPROVED. A research pass still does not authorize live execution.

## 10. Safety boundary

Default state is OBSERVE_ONLY. The module must have no dependency on order-send APIs and no path to modify EA risk or execution settings. Integration, if ever approved, is limited initially to publishing a ranked observation to the intelligence layer. A separate approval and validation process is required before any execution influence.
