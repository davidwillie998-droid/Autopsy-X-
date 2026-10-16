# FLIPDEMON EXTREME: Pyramiding Research and Validation Protocol

**Status:** Research/specification only. No EA execution or risk settings are changed by this document.  
**Scope:** MT5 implementation of trend-confirmed add-ons for FLIPDEMON EXTREME.  
**Safety posture:** Analysis/paper mode only until the full validation sequence passes.

## 1. Decision to be tested

Does adding to a confirmed winning trend improve out-of-sample, net-of-cost risk-adjusted performance versus a single-entry baseline when all variants are compared under an equivalent portfolio risk budget?

This is an empirical question, not an assumed benefit. A larger number of positions or higher gross profit alone is not evidence of improvement.

## 2. Research basis and limitations

1. **Miles, “Constant-collateral pyramiding trading strategies in futures markets” (2013), Financial Markets and Portfolio Management.** DOI: https://doi.org/10.1007/s11408-013-0216-7  
   Directly relevant to pyramiding constraints and the relationship between capital/collateral and the number of contracts. It supports explicit capital and margin constraints, not a claim that pyramiding is always profitable.

2. **Bajgrowicz & Scaillet, “Technical trading revisited: False discoveries, persistence tests, and transaction costs” (2012), Journal of Financial Economics.** DOI: https://doi.org/10.1016/j.jfineco.2012.06.001  
   Motivates protection against selection bias and explicit transaction-cost modeling when evaluating trading rules.

3. **Strub, “Trade Sizing Techniques for Drawdown and Tail Risk Control” (SSRN working paper).** https://ssrn.com/abstract=2063848  
   Relevant to comparing sizing policies using drawdown and tail-risk measures. Treat as working-paper evidence, not definitive validation of a particular sizing rule.

4. **Zarattini, Pagani & Wilcox, “Does Trend-Following Still Work on Stocks?” (SSRN working paper).** https://papers.ssrn.com/sol3/papers.cfm?abstract_id=5084316  
   Provides a motivation to investigate the contribution of extended winners to trend-following outcomes. It is not direct proof that pyramiding improves performance, and stock results may not transfer to XAUUSD or other FX symbols.

5. **Official MQL5 trade/position documentation.** https://www.mql5.com/en/docs/trading  
   Use as implementation reference for broker requests, positions, deals, and execution-state reconciliation. Validate behavior separately on netting and hedging accounts.

**Evidence boundary:** Much of the available literature concerns futures, equities, or general portfolio sizing. Transfer to XAUUSD/FX and this EA must be established with reproducible tests. Do not represent backtest results as proof of future profitability.

## 3. Candidate variants

Use identical underlying entry signals, exit logic where technically comparable, data windows, and execution-cost assumptions. Keep a single-entry baseline.

- **A — Baseline:** One initial position; no add-ons.
- **B — Equal-size add-ons:** Add only after a confirmed continuation; each increment uses the same nominal sizing rule, constrained by remaining risk budget.
- **C — Increasing add-on sizes:** Later increments may be larger only when recalculated aggregate risk, margin, and exposure remain within limits. Test several predefined schedules; do not optimize one schedule on the final test set.
- **D — Risk-adaptive add-ons:** Add-on size depends on stop distance, volatility, remaining risk budget, drawdown state, and execution quality.
- **Position-count sensitivity:** Evaluate caps of 1, 3, 5, and 15 as separate configurations. Fifteen is an experimental upper bound, not a target and not enabled for live trading by this research document.

All variants must be compared at an equivalent initial and maximum risk budget. Also report the results using the current production-configured caps as a separate compatibility check.

## 4. Entry/add-on hypothesis

A new add-on is eligible only when all applicable gates pass:

1. The original directional thesis remains valid.
2. A fresh continuation event is confirmed using predeclared price-structure/momentum rules; no future-bar information may enter the signal.
3. Existing positions are not being averaged down under this strategy. Add-ons require the defined winning/continuation condition.
4. Combined account-currency stop risk is recalculated across open positions and proposed order, including costs/slippage assumptions.
5. Symbol, direction, correlated exposure, gross lots, margin, drawdown, spread, fill quality, trading frequency, and broker constraints pass.
6. The broker's actual position/deal state is reconciled before another order can be sent.
7. If data is stale, risk cannot be computed, order acknowledgement is ambiguous, or any safety check fails, fail closed and do not add.

A breakeven stop on the first entry does not make the complete pyramid risk-free. Gaps, slippage, spread widening, and simultaneous correlated losses must be included in stress testing.

## 5. Risk controls to preserve

- Existing risk, gross-lot, margin, daily/weekly drawdown, loss-streak, spread, slippage, execution-failure, and account-health guards remain in force.
- Raising the position cap must not silently raise the permitted aggregate loss.
- Reconcile current account-wide cap and per-symbol/directional exposure logic before implementation; define netting versus hedging behavior explicitly.
- Recalculate risk and projected margin immediately before order submission and after volume normalization.
- Do not blindly retry market orders after ambiguous timeouts or connection failures.
- Analysis-only/paper modes remain the default for testing. Live mode remains disabled until separately authorized and all validation gates pass.

Any existing EA parameter that conflicts with these rules must be resolved explicitly, not silently weakened.

## 6. Experimental protocol

### Data and execution assumptions
- Use tick data where available; otherwise document timeframe and modeling limitations.
- Use chronological train/validation/test partitions and a final untouched holdout.
- Include realistic spread, commission, swap/financing where applicable, slippage, latency, rejected orders, partial fills if supported, and adverse execution scenarios.
- Prevent look-ahead, survivorship, and selection leakage. Freeze signal definitions and parameter search ranges before the final holdout.
- Evaluate distinct market regimes: persistent trends, ranges/chop, high volatility, low liquidity/wide spreads, session transitions, and abrupt reversals.
- Test both MT5 netting and hedging semantics where relevant. Verify ticket ownership, position aggregation, partial closes, stop updates, and restart/recovery behavior.

### Metrics (net of modeled costs)
- Expectancy in R and account currency; profit factor; return and volatility.
- Maximum equity drawdown, drawdown duration, expected shortfall/tail loss, and ruin-risk estimate with stated assumptions.
- Maximum and average aggregate stop risk, gross lots, directional/correlated exposure, margin use, and time at risk.
- Turnover, trade count, spread/slippage sensitivity, order failure rate, missed/duplicate-order checks, and performance by regime.
- Incremental contribution of add-ons separately from the initial entry, including whether add-ons increase profit while worsening tail loss.

### Statistical discipline
- Report confidence intervals or bootstrap uncertainty for key metrics.
- Correct for multiple configurations/parameter searches; do not select the best-looking result from many trials without accounting for selection.
- Require the result to remain directionally robust under increased transaction costs and reasonable parameter perturbations.
- A higher gross profit or win rate alone cannot pass the test.

## 7. Proposed acceptance gates

These are proposed engineering gates to review before running tests, not claims that a result has already passed.

1. **Correctness:** Unit/integration tests cover every gate, lot normalization, aggregate risk calculation, netting/hedging behavior, broker rejection, ambiguous acknowledgement, restart recovery, and duplicate-order prevention.
2. **Safety invariants:** No test path may exceed configured aggregate risk, margin, exposure, or drawdown locks because the pyramid cap was raised. If a check cannot be computed, no add-on is sent.
3. **Out-of-sample value:** At least one pyramiding variant improves a predeclared risk-adjusted metric over baseline on the untouched holdout, with uncertainty reported and without unacceptable deterioration in tail risk or drawdown.
4. **Robustness:** The improvement survives higher costs, adverse fills, different market regimes, and small parameter changes; it is not dependent on one symbol, short period, or a few outlier trades.
5. **Operational validation:** Static CI passes, MetaEditor compilation succeeds without errors, Strategy Tester passes, then demo forward testing demonstrates correct live broker-state reconciliation and risk behavior.
6. **Release control:** No live enablement or PR merge solely because static tests pass. Human review and demo validation remain mandatory.

Numerical profitability thresholds must be approved before the final holdout is opened; do not invent them after seeing results.

## 8. Implementation sequence

1. Review the current EA source and enumerate all position-count, risk-budget, sizing, order-submission, close, and recovery paths.
2. Add a testable pyramiding policy module/specification without changing the default live behavior.
3. Unit-test aggregate risk and incremental sizing independently of MT5 execution.
4. Add controlled backtest variants and a machine-readable report that records data provenance and configuration.
5. Run the frozen chronological out-of-sample experiment.
6. If and only if evidence and safety gates pass, implement the selected policy behind an explicit opt-in input, default off.
7. Compile, run MT5 Strategy Tester and demo forward tests. Keep live execution disabled until a separate approval decision.

## 9. Current conclusion

Pyramiding is a testable strategy hypothesis, not a proven improvement. The most defensible next engineering step is to audit the existing EA's position and risk paths and create a reproducible comparison harness. Do not change the position cap or increase lot sizes before that work and the acceptance gates are complete.


## 10. Opportunity-quality and pyramid matrix (design refinement)

The objective is **not** to maximize position count. It is to deploy a controlled risk budget into a high-quality, confirmed market opportunity and scale only while the original thesis remains valid.

### 10.1 Separate the decisions

The EA must calculate three separate outputs. Do not collapse them into one opaque “confidence-to-lot” multiplier.

1. **Opportunity eligibility:** Is the market setup allowed at all? Hard gates include data freshness, tradable regime, spread/liquidity, valid stop placement, session/news restrictions if implemented, and execution health.
2. **Campaign risk budget:** How much account-currency risk remains available after existing open positions, correlated exposure, current drawdown state, margin, and account-wide limits?
3. **Increment size:** Given the remaining risk budget and proposed stop, what is the largest broker-valid volume that stays inside every limit? Round down to the broker's volume step; if the minimum volume breaches the budget, reject the add-on.

A high signal score can qualify a setup for consideration, but must not bypass a hard gate or directly force a larger lot.

### 10.2 Market-condition assessment

Record each input separately and make the decision auditable.

| Dimension | Favorable evidence | Defensive/block condition |
|---|---|---|
| Trend/structure | Confirmed directional structure; continuation holds | Structure breaks or thesis invalidates |
| Momentum | Persistence and fresh continuation confirmation | Momentum fades, divergence/impulse failure under predeclared rules |
| Volatility | Stop distance and current volatility remain within the model's tested range | Volatility shock makes stop risk or execution unreliable |
| Liquidity/execution | Spread and fill quality acceptable; depth used only if reliable and available | Spread spike, stale quotes, repeated poor fills, ambiguous broker state |
| Regime | Regime belongs to the strategy's validated set | Chop/chaotic/unsafe regime or out-of-distribution conditions |
| Account state | Risk headroom, margin and drawdown gates all pass | Any cap/lockout is reached or risk cannot be calculated |

The model must not treat a missing optional feed (such as depth/heatmap) as positive evidence. Missing required inputs should either trigger a documented fallback tested in advance or block the add-on.

### 10.3 Pyramid stages to evaluate

These are candidate stages for research, not enabled trading settings.

| Stage | Cumulative positions | Required decision |
|---|---:|---|
| Initial | 1 | Valid entry setup and full risk pre-flight |
| Add 1 | 3 | Fresh continuation confirmation; recalculate full campaign risk |
| Add 2 | 5 | Trend still valid; add-on contribution and execution quality acceptable |
| Add 3 | 8 | Extended mode only; stricter regime/liquidity and drawdown checks |
| Add 4 | 12 | Extended mode only; remaining risk budget and margin headroom demonstrated |
| Add 5 | 15 | Hard experimental ceiling; every gate passes, otherwise no order |

At each stage, the number of positions is only a ceiling. The EA must not fill all stages simply because a trend is strong. It may stop at 1, 2, or 4 positions if risk or execution conditions do not justify the next tranche.

### 10.4 Lot sizing and increasing lots

Test a monotone target-lot schedule (later add-ons are intended to be larger) against equal-size and risk-adaptive alternatives. Do not force actual lots to increase if the safe size decreases because volatility or stop distance increased.

For each proposed tranche, calculate the loss at its proposed stop in account currency using broker-aware contract/tick-value calculations (or a validated platform profit-calculation method), then calculate the maximum volume permitted by the remaining campaign-risk budget. Apply all other caps, normalize volume downward, and re-check the final normalized order. If the proposed larger lot fails any check, reduce it to the safe size or reject the addition; never relax a limit to preserve the pyramid shape.

Illustrative calculation only:
- remaining risk money = campaign risk limit money - current open positions' stop risk money - reserved cost buffer money
- risk per lot = absolute account-currency loss at proposed stop for 1 lot + conservative cost allowance per lot
- risk-limited lots = remaining risk money / risk per lot
- allowed lots = minimum of risk-limited lots, gross-lot headroom, directional headroom, symbol headroom, margin-limited lots, and liquidity-limited lots
- Normalize allowed lots **down** to broker volume step, then recalculate final risk and margin. Reject if any invariant fails.

The campaign risk limit must be explicit and compatible with the existing InpExtremeRiskPercent, adaptive risk multipliers, account-wide position cap, 1.0-lot gross/directional caps, and margin controls. These existing defaults conflict with a 15-position ambition unless reviewed together; this protocol does not change them. Define whether risk is measured against initial campaign equity, current equity, or another fixed reference, and never let equity gains silently increase the campaign budget during the same campaign.

### 10.5 Pyramiding stop and exit policy

- Every tranche must have a valid broker-accepted protective stop when required by the strategy and broker; confirm the actual installed stop after fill.
- Model the combined campaign's loss under a simultaneous stop scenario, gaps and adverse slippage—not just each ticket independently.
- Moving an older stop to breakeven may reduce modeled stop risk but does not eliminate gap, spread, latency, or stop-execution risk.
- If the trend thesis is invalidated, the campaign manager must have a deterministic action for all related positions. Define whether the response is close-all, staged reduction, or existing exit-engine ownership; test it before implementation.
- Prevent an opposite-signal flip from accidentally opening a new pyramid before the prior campaign's broker state has been reconciled.

### 10.6 Required audit trail

For every accepted or rejected add-on, log: campaign ID, signal snapshot/time, regime, structure/momentum evidence, spread and available liquidity data, current and proposed positions, stop distance, per-lot risk, current and proposed aggregate risk, margin before/after, each gate result and rejection reason, requested/normalized/filled volume, broker retcode, actual installed SL/TP, latency/slippage, and the resulting account state. This supports reproducibility and root-cause analysis.

### 10.7 Additional acceptance tests

- A high-confidence signal with insufficient risk headroom is rejected.
- A low-quality/unsafe regime is rejected regardless of available margin.
- Increasing volatility or wider stops reduces the permitted lot size when necessary; the target lot ladder never overrides the risk calculation.
- Volume normalization cannot push aggregate risk or gross lots over a cap.
- Partial fills, netting aggregation, hedging tickets, terminal restart, ambiguous timeout, stale quotes, stop-modification failure and manual/foreign positions cannot cause duplicate additions or ownership errors.
- If any required risk input is unavailable or inconsistent, no new tranche is sent.
