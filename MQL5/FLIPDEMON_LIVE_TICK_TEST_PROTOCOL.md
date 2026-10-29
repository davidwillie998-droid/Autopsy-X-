# FlipDemon Extreme HFT — Live-Tick MT5 Validation Protocol

## Purpose
Validate the EA against the broker's actual historical tick stream and variable spread, then compare adaptive sizing/pyramiding behavior against the same data and settings. This document is a test protocol, not evidence that a run has passed.

## Non-negotiable distinction
- Live market data means prices streamed from a connected broker in real time.
- Real ticks in Strategy Tester means broker-supplied historical ticks replayed by MT5. A historical test cannot use future live ticks.
- 99% modelling quality is a tester report metric, not a profitability certificate. Preserve the full report and don't promise a specific number before seeing it.
- Do not synthesize tick history or replace missing real ticks with fabricated values to make a score look better.

## Data preparation
1. Connect MT5 to the exact broker/server intended for evaluation.
2. In Market Watch, show the exact broker symbol, including any suffix. Do not assume symbols share contract size, tick size/value, volume step, stop level, swap, or commission.
3. Open the symbol in charts and History Center where available; request/download history for the full test period. Let MT5 finish downloading broker history before starting.
4. Record broker/server, symbol, timeframe, date range, account currency, leverage, contract size, commission schedule, swap settings and terminal build.
5. For the intended broker's execution conditions, use that broker's history. A demo login may still provide that broker's historical data; the important issue is the source and completeness of the tick history, not the label of the login alone.

## Strategy Tester configuration
1. Select FlipDemon Extreme HFT and the exact broker symbol.
2. Set the intended timeframe; record both the tester timeframe and the EA's own configured signal/regime timeframes.
3. Select Every tick based on real ticks, not Open prices only, 1-minute OHLC, or generated ticks.
4. Use a date range for which the broker has real ticks. If MT5 reports missing history or fallback/generated ticks, stop and document the issue rather than treating the run as a real-tick test.
5. Keep spread on the tester's historical/current spread behavior. Do not type a fixed spread for the primary run. Confirm the test is replaying historical bid/ask variation.
6. Set actual commission and swap assumptions. Verify whether the tester applies them automatically; do not double-count commission through both the tester and custom EA inputs.
7. Record deposit, account currency, leverage, execution delay/slippage settings, and all EA inputs. Keep the .set file and full tester report.
8. Run ANALYSIS_ONLY first to verify signals and safety behavior. Test order execution only in Strategy Tester or a dedicated demo environment after compilation and safety checks. Never use a funded account as the first execution test.

## Test matrix
Run each case on identical historical data and settings, changing one factor at a time:
- Baseline sizing with current conservative limits.
- Equity-growth sizing with per-entry risk ceiling and aggregate-risk controls enforced.
- Conditional campaign additions only after unique fresh continuation signals.
- Variable spread and costs during normal sessions, rollover, and illiquid periods represented in the history.
- Stress cases: spread exceeds limit, invalid stop, broker minimum volume exceeds risk budget, insufficient margin, rejected/requoted order, partial fill, partial close, stop moved to break-even, restart with open position, and missing/corrupt recovery state.
- Out-of-sample date range and walk-forward periods. Do not optimize and report performance on the same period only.

## Required evidence per run
Save the complete Strategy Tester HTML report and journal/log, not just a screenshot of the headline metric. Record:
- Tester model and tick-data source.
- Modelling quality / real-tick status as actually shown by MT5.
- Tick count, bars, date range and any history gaps.
- Variable spread behavior and observed spread distribution.
- Net profit after costs, profit factor, expected payoff, trade count, max balance/equity drawdown, recovery factor, margin level, and risk-of-ruin estimate.
- Commissions, swaps, slippage/execution assumptions and rejected orders.
- Whether campaign ledger reconciled every fill/partial close/restart without mismatch.
- Code commit, terminal build, broker server, symbol specification and .set file.

## Acceptance gates before live mode
- MetaEditor compilation has zero errors; warnings are reviewed.
- Static safety audit and repository CI pass on the exact commit.
- Real-tick tester run completes without missing-history/fallback ambiguity.
- Per-entry, campaign and account-wide stop-risk calculations are checked against broker-calculated PnL.
- Campaign ledger reconciles netting-account deal attribution, partial reductions, stop changes, external intervention and restarts. If it cannot reconstruct state, new entries/additions remain blocked.
- No addition is allowed on a losing campaign, on a reused signal ID, or when campaign/account risk, margin, spread, daily/weekly loss, execution-quality or recovery gates fail.
- Results remain robust after commission, swap, variable spread and conservative slippage, and on out-of-sample periods.
- Live mode remains an explicit operator choice; it is not the default and is not activated merely because a backtest reports high modelling quality.

## Multi-broker portability requirement

Universal broker-support requirement: FlipDemon Extreme HFT is intended to work across all brokers that expose compatible instruments and supported MT5 execution/account capabilities—not only Exness, Weltrade, Deriv and Tickmill. Those four are initial validation environments, not an exhaustive broker whitelist. Do not hard-code a four-broker allowlist. Discover capabilities from the connected terminal and symbol/account metadata at runtime; use explicit broker-specific adapters or exceptions only when a verified incompatibility requires them. A broker or instrument that lacks a required capability must be rejected safely with a precise reason, not silently treated as supported.

- At initialization, log broker/company, server, terminal build, account currency, margin mode (netting/hedging), leverage, symbol name and all relevant symbol properties.
- Read symbol properties at runtime: digits, point, tick size, tick value/profit/loss where available, contract size, volume min/max/step/limit, stops/freeze levels, execution and filling modes, trade mode, margin settings, swap mode/values, and current trading sessions.
- Use OrderCalcProfit and OrderCalcMargin with the intended symbol, direction, volume, entry and stop; fail closed when calculations fail or minimum volume would exceed the risk budget.
- Do not infer instrument identity from a symbol substring alone. Use explicit per-symbol capability/configuration where the strategy requires market-specific assumptions.
- Deriv synthetic indices are provider-generated derived markets, not ordinary exchange-traded FX/gold. Their tick behavior, contract economics, sessions, spreads and history availability must be tested per index; do not reuse FX/gold thresholds without validation.
- Spread limits must be expressed and compared in a clearly defined unit (broker points or price units) and logged with bid, ask, point and tick size. A single raw points threshold may not be portable across symbols.
- Historical data availability differs by broker, server, account type and symbol. Verify that Strategy Tester is replaying the selected broker's real ticks and variable bid/ask history; do not claim one broker's ticks reproduce another broker's execution.
- Keep broker-specific exceptions explicit, documented, and covered by tests. If an account mode or execution capability is unsupported, initialization or new entries must be blocked with a clear reason.

### Required broker test matrix

Test each broker independently, using the exact server and symbol names exposed in that MT5 terminal. The initial matrix must include Exness, Weltrade, Deriv and Tickmill, then expand to additional compatible brokers rather than treating those four as the full support universe. Test XAUUSD and major FX where offered; test Deriv synthetic indices as a separate instrument family. Capture the full Strategy Tester report, Journal, symbol specification, .set file and commit SHA for every run. A successful test on one broker does not certify another broker, server, account mode or instrument.
## Current status
Protocol written; not executed. No 99% modelling-quality result, MT5 compilation, Strategy Tester result, or profitability result is claimed. The existing EA still needs the campaign ledger and aggregate-risk enforcement before additional-entry/pyramiding limits can safely be relaxed.