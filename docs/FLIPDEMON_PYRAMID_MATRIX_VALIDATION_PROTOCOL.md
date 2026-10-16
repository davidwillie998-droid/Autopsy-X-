# FLIPDEMON EXTREME Pyramid Matrix: Validation Protocol

**Status:** Proposed validation contract. This document is not evidence of a profitable strategy and does not authorize live execution.

## 1. Research question

Does adding to a profitable campaign, only after fresh continuation confirmation, improve net risk-adjusted outcomes over a single-entry baseline without breaching the same predeclared campaign-risk and exposure constraints?

The experiment must distinguish:
- the value of the initial signal;
- the incremental value of each additional entry;
- the cost of execution and increased exposure;
- the effect of regime filters;
- the bias introduced by choosing among many schedules and thresholds.

## 2. Freeze the experiment before running it

Before the final test, record and version:
- data source, symbol, broker contract specification, account mode, time zone and session calendar;
- bar/tick range, missing intervals, and data-quality exclusions;
- entry and exit definitions, initial stop, add-on trigger and invalidation;
- maximum campaign risk, cost reserve, spread limits, margin limits and volume-normalization policy;
- all candidate schedules and parameter ranges;
- slippage, latency, rejection and stop-gap assumptions;
- chronological train, validation, walk-forward and final untouched holdout periods.

Do not change thresholds after viewing the final holdout. If rules change, the holdout is no longer untouched and a new period is required.

## 3. Required baseline and ablations

Run the same underlying signal with the same initial campaign risk budget:
1. Single entry, no add-ons.
2. Equal-size add-on targets.
3. Increasing target lots with multiplier values declared before testing.
4. Risk-adaptive targets that can only reduce the target under weaker quality.
5. Negative controls with continuation confirmation disabled and/or add-ons allowed while losing. These are diagnostic controls only and must never be candidates for release.

All variants must use the same hard campaign-risk cap and equivalent execution assumptions. A larger nominal target may be clipped or rejected by risk sizing; report both requested and accepted lots.

## 4. Event ledger required for every decision

Persist one record for each candidate add-on, including rejected decisions:
- run ID, strategy version, campaign ID, symbol, direction, timestamp and session;
- signal age, continuation evidence, regime label, thesis status and extension/chase measure;
- bid, ask, spread, volatility, available liquidity proxy and cost reserve;
- open/pending volume by account, symbol, direction and campaign;
- current and projected stop risk in account currency;
- equity reference used for the fixed budget, remaining risk budget and risk per lot;
- margin before/after, free margin, margin level and exposure headroom;
- requested target lots, computed safe lots, broker minimum/maximum/step, normalized lots;
- allow/block outcome with stable reason codes;
- order request, retcode, latency, requested/fill price, actual fill volume, actual SL/TP, partial fill and reconciliation outcome;
- eventual campaign P/L net of commissions, swaps and slippage, max adverse excursion, max favorable excursion and exit reason.

Use point-in-time inputs only. No later candle, future fill or revised historical label may influence an earlier decision.

## 5. Required metrics

Report per variant and by symbol, session, direction, volatility regime, spread regime, campaign stage and market shock:
- number of campaigns and eligible/rejected add-ons;
- expectancy per campaign and per unit of initial risk, net of costs;
- profit factor, win/loss distribution, median result and tail quantiles;
- maximum drawdown, drawdown duration, worst campaign loss and gap/stop stress loss;
- realized versus modeled slippage, rejection rate and missed/ambiguous fills;
- average and peak gross/directional exposure, margin usage and risk-budget utilization;
- incremental P/L attributable to add-ons versus the no-add baseline;
- bootstrap confidence intervals clustered by campaign or trading day, with method documented;
- performance degradation under spread/slippage/latency stress;
- parameter stability across walk-forward windows and symbols.

Never present win rate or gross return alone as proof of quality.

## 6. Minimum pass conditions

These are safety and evidence gates, not claims that any numeric performance threshold is universally correct.

### Data integrity
- No look-ahead or survivorship leakage identified by the audit.
- Timestamps, point-in-time quotes and broker contract metadata are traceable.
- Missing data and rejected/corrupt intervals are reported, not silently filled in ways that create trades.
- The final holdout is untouched by tuning.

### Safety invariants
- Every hard gate fails closed when false, missing, stale or invalid.
- No add-on is allowed without fresh continuation confirmation.
- No add-on is allowed to a losing campaign.
- Projected aggregate risk never exceeds the fixed campaign budget after costs and volume normalization.
- Projected account, symbol and directional exposure and margin remain within configured caps.
- Minimum-volume rounding cannot increase risk above the cap.
- A state-reconciliation failure, ambiguous order acknowledgement, missing stop confirmation or execution lock blocks further adds.
- Restart/reconnect recovery reproduces the same campaign state before trading can resume.

### Strategy evidence
- The pyramid variant improves a predeclared net-of-cost objective versus the single-entry baseline on walk-forward data.
- The improvement is not confined to one symbol, one short period or a small number of outlier campaigns.
- Drawdown, tail loss and stressed execution remain inside predeclared tolerances.
- Results survive reasonable cost shocks and parameter perturbations.
- Multiple testing / selection bias is addressed, and uncertainty is reported.

If the evidence is inconclusive, prefer the simpler single-entry baseline. Do not lower safety gates to make a variant pass.

## 7. Test cases required before integration

- stale or missing continuation timestamp;
- thesis invalidation between signal and order submission;
- regime flips to range/shock state;
- spread spike after sizing but before submission;
- risk budget nearly exhausted, including a broker minimum volume that is too large;
- decimal volume-step edge cases such as 0.1, 0.25, 0.001 and non-decimal binary representations;
- pending orders and partial fills included in aggregate exposure;
- rejected order, timeout, disconnect and delayed broker acknowledgement;
- stop missing, rejected or modified unsuccessfully;
- manual/foreign ticket appears during a campaign;
- terminal restart and broker reconciliation;
- netting and hedging account behavior explicitly supported or safely rejected;
- gap through stop, adverse slippage, and margin deterioration;
- daily/weekly lock or loss-streak lock activates while a campaign is open;
- duplicate event/tick does not create duplicate add-ons;
- campaign close and partial close update risk accounting correctly.

## 8. Release sequence

1. Research protocol reviewed and frozen.
2. Reference-model tests cover every test case feasible in Python.
3. Static MQL5 invariants verify the default-off flag, existing hard gates, and no bypass path.
4. MetaEditor compile against the intended terminal build; review all warnings.
5. Strategy Tester run with documented tick model and costs; archive raw report and input set.
6. Demo forward run across distinct sessions and volatility conditions; reconcile every decision and deal with broker history.
7. Independent review of source diff, risk calculations, test artifacts and remaining limitations.
8. Explicit release approval. Keep analysis/paper mode default; no live activation merely because CI is green.

## 9. Decision rule

Promote only when every safety invariant passes and the predeclared net-of-cost objective beats the baseline with credible out-of-sample evidence. If it fails or remains uncertain, disable pyramiding and retain the single-entry behavior. A passing unit test proves only the tested contract, not future profitability or broker correctness.
