# FLIPDEMON Investment Thesis and Decision Validation Contract

Status: **RESEARCH CONTRACT / NOT A PROFITABILITY CLAIM**
Applies to: FlipDemon Extreme MT5 strategy on supported broker-provided FX, metals, CFDs and synthetic indices.
Execution default: `ANALYSIS_ONLY`. This document does not authorize order submission or change execution mode.

## 1. Investment thesis

FlipDemon seeks positive net expectancy by selectively trading confirmed transitions in market structure and directional participation. It evaluates liquidity events, structural displacement, VWAP location, momentum and market regime, then rejects opportunities when evidence conflicts, data quality is inadequate, execution costs are excessive, or account risk is unavailable.

The proposed edge is **conditional and falsifiable**. No indicator, confluence count, score, backtest, or source-level test establishes profitability by itself.

## 2. Testable hypotheses

Each hypothesis must be preregistered with a versioned definition, feature set, target, test window, minimum sample requirement, benchmark and kill criterion before opening its out-of-sample period.

| ID | Hypothesis | Comparison | Kill condition |
|---|---|---|---|
| FD-H1 | Confirmed structure displacement improves directional trade expectancy | BOS/CHOCH-confirmed entries vs the same signal family without structural confirmation | No positive net expectancy improvement out of sample |
| FD-H2 | Liquidity sweep plus completed-bar reclaim identifies better reversal entries | Sweep-and-reclaim vs sweep-only and a time-matched baseline | Effect is absent, reverses, or is explained by costs |
| FD-H3 | VWAP alignment adds information beyond momentum and structure | Full model vs ablation without VWAP | VWAP does not improve out-of-sample net expectancy or calibration |
| FD-H4 | Higher-timeframe agreement improves selectivity | Aligned vs neutral/conflicted HTF state, with identical entry/exit rules | No robust improvement after controlling for trade frequency and regime |
| FD-H5 | Regime-conditional rules outperform one global rule set | Frozen regime-conditioned model vs global baseline | Regime model fails across walk-forward folds or adds unstable complexity |
| FD-H6 | WAIT filtering improves return per unit of risk | Qualified decisions vs all candidate signals before final gates | Filtering does not improve net expectancy, drawdown or tail loss |
| FD-H7 | Footprint/delta or volume-profile evidence adds independent value where broker data supports it | Full model vs feature ablation on data with verified provenance | No incremental out-of-sample value, or feed limitations invalidate the feature |

A hypothesis may be supported, inconclusive or killed. A killed hypothesis remains in the research ledger. Changing its definition after viewing test results creates a new hypothesis ID.

## 3. Instrument and data boundaries

- Evaluate each broker symbol independently first. Do not pool XAUUSD, GBPJPY, FX pairs and synthetic indices into one headline result.
- Record broker, server, exact symbol, contract specification, account currency, timeframe, terminal build, tick source, spread, commission, swap and execution assumptions.
- Use only features available at the decision timestamp. Structural and indicator features used for a bar-close decision must be derived from completed bars; no future bar, revised label, or post-entry value may leak into the signal.
- Treat real-volume, tick-volume, footprint, depth and heatmap fields according to their actual feed provenance. Missing or unsupported data is unavailable, never silently fabricated.
- Keep the event clock, broker timestamps and UTC-normalized research timestamps explicit.

## 4. Repeatable decision contract

For a fixed market-data snapshot, symbol specification, account snapshot, configuration version and code version, the analytical decision must be deterministic.

Every candidate decision must record:

- Decision ID and unique setup/signal ID.
- Timestamp, symbol, timeframe, completed-bar timestamp and data freshness.
- Code commit, strategy/config version and configuration hash.
- Market regime and the evidence used to classify it.
- BUY score, SELL score, score gap and component-level contributions.
- Feature availability and data-quality status.
- Proposed direction and final action: BUY, SELL or WAIT.
- Every failed hard gate and every unmet soft criterion, with a stable reason code.
- Entry reference, invalidation/stop, target logic, spread and estimated transaction costs.
- Hypothetical volume, monetary stop risk and risk as a percentage of equity.
- Whether execution was permitted, denied or not evaluated.

The same analytical inputs and configuration must produce the same scores, reason codes and BUY/SELL/WAIT result. Account and broker gates are evaluated against a separately timestamped, fresh snapshot; a changed account state may legitimately change execution permission without changing the market thesis.

### Decision semantics

- **BUY:** bullish evidence clears the frozen score and separation thresholds, all mandatory data checks pass, and execution/risk gates approve.
- **SELL:** bearish evidence clears the same frozen thresholds and all mandatory gates approve.
- **WAIT:** evidence is insufficient or conflicted, a required input is unavailable/stale, costs are excessive, or any hard gate denies permission.

WAIT is a valid terminal analytical outcome. It must not be converted into an order by a downstream component.

### Existing score interpretation

The current `SignalScore.mqh` baseline uses microstructure/liquidity/momentum weights of 0.40/0.25/0.35, a minimum directional score of 60 and a minimum BUY/SELL gap of 15. Its reported confidence is derived from score separation (`gap * 1.15`), so it is a **heuristic score, not a calibrated probability of winning**. Regime aggression scaling also changes the displayed scores. Preserve this baseline for comparison; do not tune weights on the final test set or describe its confidence as a probability until calibration has been measured.

## 5. Execution and capital-preservation constraints

- Preserve `ANALYSIS_ONLY` as the default. Research and decision logging do not grant execution authority.
- The immutable account-wide open stop-risk ceiling is **2.00% of current equity in aggregate**, across all controlled positions, pending orders and outstanding reservations. It is one shared ceiling, not 2% per symbol, per campaign, or per terminal.
- Per-entry and campaign limits may be stricter; none may increase the aggregate 2.00% ceiling.
- Unknown exposure, invalid/missing protection, stale snapshots, unresolved submissions, uncertain broker outcomes, unreconciled reservations, or failed audit persistence must fail closed.
- Never average down, martingale, force broker minimum volume above the risk budget, or reuse a consumed signal ID.
- Profitable campaign additions require a distinct, fresh continuation decision and a complete recalculation of remaining aggregate risk before reservation.
- Leverage is a margin parameter, not a multiplier for monetary risk.

## 6. Validation protocol

### Baselines and ablations

Compare the frozen full strategy against:
1. A simple directional baseline using the same instrument, timeframe, entry timing and exits.
2. The existing frozen FlipDemon score model.
3. Each feature family removed individually (structure, liquidity, VWAP, momentum, HTF, regime, footprint/delta where valid).
4. A WAIT-filter ablation to measure whether each gate contributes value or merely reduces trade count.

Change one feature family at a time. Keep entry, exit, sizing and cost assumptions identical within each comparison.

### Chronological evaluation

- Split by time, never random shuffle.
- Use rolling or expanding walk-forward folds. Training and parameter selection must precede each test fold.
- Purge overlapping outcome windows and apply an embargo where labels or holding periods overlap fold boundaries.
- Keep a final untouched out-of-sample period. Open it once after all definitions and parameters are frozen.
- Report each instrument and regime separately, as well as any aggregate with instrument-level results visible.
- Include enough trades and independent market episodes to make uncertainty visible. Report sample counts and confidence intervals; mark underpowered results inconclusive rather than passing them.

### Realistic return measurement

Measure each trade from the first actually fillable price, not the signal close. Deduct broker-specific spread, commission, swap and conservative slippage. Model rejected, partial and delayed fills where the data permits. Do not use a fixed spread as the only primary scenario when variable-spread tick data is available.

Report at minimum:
- Net expectancy in R and account currency.
- Profit factor and win/loss distribution.
- Average win, average loss and payoff ratio.
- Maximum equity drawdown and time under water.
- Trade count, exposure time and turnover.
- MAE/MFE and stop/target execution quality.
- Results by instrument, regime, session and setup family.
- Confidence intervals, fold dispersion and parameter sensitivity.
- Cost stress and adverse execution scenarios.

A positive in-sample result, a high win rate, a high modelling-quality percentage, or a single profitable fold is not sufficient evidence of an edge.

## 7. Acceptance and falsification

A setup is eligible for promotion only when:
1. Its hypothesis and acceptance criteria were frozen before out-of-sample evaluation.
2. Net expectancy is positive after realistic costs, with uncertainty reported.
3. The effect persists across multiple chronological folds and is not concentrated in one market episode.
4. The result is not destroyed by modest parameter perturbations or conservative cost stress.
5. Ablation shows which features add incremental value.
6. No material lookahead, survivorship, selection or data-quality defect is found.
7. Signal decisions are reproducible from the recorded snapshot and configuration.
8. The safety and lifecycle suites remain green on the exact commit.

If the evidence is weak, contradictory or underpowered, retain the setup in ANALYSIS_ONLY and label it inconclusive. If the predefined kill criterion is met, disable that setup through a versioned change. Do not silently retune it to rescue the result.

## 8. Required research outputs

Maintain a versioned hypothesis ledger with: hypothesis ID, status, feature definition, target/label definition, data provenance, preregistration date, sample size, folds, baseline, ablations, net metrics, uncertainty, kill/support decision, code commit and reviewer notes.

Every reported result must identify whether it is:
- a source/static assertion,
- a deterministic unit or reference test,
- a historical backtest,
- a real-tick Strategy Tester result,
- a demo forward result, or
- a live execution result.

Never describe one evidence class as another. MetaEditor compilation, MT5 Strategy Tester execution and broker forward testing require their own artifacts and are not implied by Python tests or GitHub static checks.
