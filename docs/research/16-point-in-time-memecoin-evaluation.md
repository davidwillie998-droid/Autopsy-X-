# Point-in-Time Evaluation Protocol: Memecoin Structure + On-Chain Momentum

Status: proposed protocol; no performance claim is made.
Review date: 2026-10-13.
Target: Solana-first newly launched and actively traded memecoins.
Related research: PR #8, [SSRN evidence map](https://github.com/davidwillie998-droid/Autopsy-X-/pull/8).

## 1. Research question

Do TJR-inspired market-structure features (liquidity sweeps, BOS/CHoCH, displacement and FVGs) and Rasmur-inspired on-chain/narrative features (wallet cohorts, buyer breadth, swap imbalance and attention acceleration) add **incremental, executable, after-cost value** beyond simple momentum and liquidity baselines?

This protocol evaluates feature families, not the profitability or skill of any named trader. Public trader activity is not treated as ground truth or an automatic copy-trading signal.

## 2. Hypotheses to test separately

- H0: Structure and on-chain/narrative features do not improve out-of-sample results over simple baselines after costs.
- H1-S: Structure features add value beyond price/volume and liquidity baselines.
- H1-O: On-chain wallet-flow and buyer-breadth features add value beyond those baselines.
- H1-N: Narrative/attention features add value when their timestamps prove they were available before the decision.
- H1-C: Combining feature families improves net strategy outcomes without increasing tail loss or manipulation exposure beyond preregistered limits.

Do not collapse these hypotheses into one score. Report each family and its incremental contribution.

## 3. Unit of observation and eligible universe

The primary unit is a token-decision snapshot, keyed by chain, token mint, pool, decision timestamp and strategy version. Preserve every discovered token, including rejected, dead, unsellable and delisted tokens. Do not build the dataset from winners, surviving tokens, or current token lists only.

Before the test begins, freeze:
- Launch/pool eligibility rules and minimum observable history.
- Supported launch venues and pool types.
- Token-age, liquidity and market-regime strata.
- Exclusions for invalid or irrecoverably incomplete data, with explicit reason codes.
- The exact snapshot cadence and decision delay.

Report the count and percentage excluded at each rule. Missing data is not zero; missingness and collection latency are features of data quality, not silently imputed away.

## 4. Required point-in-time event schema

Every record must preserve, at minimum:

- `chain_id`, `token_mint`, `pool_id`, `venue`, `collector_version`, `schema_version`.
- `event_ts`: when the chain/event says the activity occurred.
- `first_seen_ts`: when our collector first observed it.
- `feature_ready_ts`: when the feature could actually be computed.
- `decision_ts`: when the strategy is permitted to act.
- `submit_ts`, `quote_ts`, `fill_ts`, `exit_ts`, where applicable.
- Source slot/signature or provider cursor, raw payload hash, ingestion status and data-gap flags.
- Feature values plus each feature's source window, freshness, missingness and version.
- Decision, vetoes, estimated costs, simulated order parameters and realized outcome.

At a decision timestamp, a feature is legal only if all source events used to calculate it were observable by that timestamp and `feature_ready_ts <= decision_ts`. Late-arriving events must not be backdated into the live feature vector.

## 5. Feature families

### A. Simple baselines

- Buy-and-hold over the fixed evaluation horizon where executable.
- Price-only momentum over fixed short horizons.
- Price + volume momentum.
- Liquidity/age-only ranking.
- Random or shuffled signal control, respecting token-age and decision-time strata.

### B. Structure (TJR-inspired, independently implemented)

- Confirmed swing highs/lows and equal-high/low proximity.
- Sweep and reclaim flags, with a fixed confirmation rule.
- BOS/CHoCH based only on already-confirmed pivots.
- Displacement magnitude normalized by trailing volatility.
- FVG size, age, fill state and invalidation.
- Distance from recent highs/lows and setup invalidation level.

No future candle may be used to confirm a pivot, sweep, BOS/CHoCH or FVG at an earlier decision time. Specify candle interval and confirmation delay before evaluation.

### C. On-chain and wallet flow (Rasmur-inspired research hypotheses)

- Swap buy/sell imbalance and acceleration, with venue-specific transaction semantics.
- Unique buyer count and buyer breadth, adjusted for repeated wallets.
- Wallet cohort flows and prior activity, only from history observable by decision time.
- Creator/deployer/early-holder concentration and transfers, with attribution confidence.
- Clustered funding and synchronized behaviour as probabilistic risk indicators, never proof of common ownership.
- Liquidity depth, reserve changes, pool concentration and estimated sell impact.

### D. Narrative and attention

- Abnormal mention/post volume against a trailing baseline.
- Source type, unique authors, repost/duplicate rate and engagement velocity.
- Time from first attention observation to feature readiness.
- Event/source reliability and conflict-of-interest flags where verifiable.

Attention signals arriving after the decision timestamp are excluded. Social features must have their own missingness and delay ablations.

## 6. Outcomes and labels

Use separate labels for prediction, execution and risk. The primary forward horizon must be selected and frozen before final holdout access; report additional horizons as secondary outcomes.

Prediction outcome:
- `TARGET_FIRST`: preregistered target barrier reached before adverse barrier.
- `ADVERSE_FIRST`: adverse barrier reached first.
- `NEITHER_BY_HORIZON`: neither barrier reached before horizon expiry.
- `EXIT_INFEASIBLE`: no executable exit under the declared venue/order assumptions.
- `DATA_INVALID`: essential event ordering or market data cannot be reconciled.

Set barriers using information available at decision time, with a fixed volatility/risk convention. Never tune barriers against the final holdout. Avoid labels that assume fills at a candle close, mid-price, or quoted price when that execution was unavailable.

Execution outcome must separately record whether the simulated order could be submitted, included, filled and exited, plus realized slippage, fees, price impact, failed transactions and adverse selection.

Risk outcomes must include maximum adverse excursion, maximum favorable excursion, time to exit, extreme loss, liquidity-collapse exposure and concentration in common wallets/narratives.

## 7. Execution simulation

Use a conservative, documented fill model based on the actual pool/venue and transaction path. Include:
- Pool reserves/depth at decision and submission time.
- Swap fee, priority fee/tip, network fee and other applicable costs.
- Quote-to-submit and submit-to-inclusion delay.
- Slippage tolerance, price impact and failed/reverted transaction rates.
- Partial/failed fills where applicable and exit feasibility under stress.
- Latency, fees and slippage stress scenarios.

A displayed price or TVL is not an executable price. If historical state is insufficient to model a fill credibly, classify the sample as execution-unknown and do not count it as a profitable trade.

## 8. Validation design and leakage controls

1. Sort all samples by decision time. Split chronologically into train, validation and a final untouched holdout.
2. Define split dates only after measuring data coverage; publish them before model selection.
3. Apply purging/embargo around overlapping forward-label windows and keep the same token/pool episode from leaking across splits.
4. Fit normalizers, thresholds, wallet-cluster models, feature selection and hyperparameters using training data only.
5. Use nested chronological validation for tuning. Keep the final holdout inaccessible until the feature set, thresholds, execution assumptions and primary metrics are frozen.
6. Run a walk-forward sensitivity analysis without replacing the untouched final holdout.
7. Preserve all failed/rejected candidates and record the reason for every filter and veto.
8. Log all experiments, code commit, raw-data hashes, configuration, model version and random seeds.

If the data coverage cannot support defensible chronological splits, report insufficient evidence instead of relaxing the design after seeing results.

## 9. Required ablations and falsification

Run at least these frozen variants on identical eligible snapshots:
1. Baseline price/volume only.
2. Baseline + structure.
3. Baseline + on-chain/wallet flow.
4. Baseline + narrative/attention.
5. Combined model.
6. Combined model without wallet-cluster features.
7. Combined model without social/narrative features.
8. Combined model under conservative latency/slippage/fee stress.
9. Negative control with time-shuffled or within-stratum shuffled signals.
10. Survivorship-sensitive comparison including all discovered token outcomes.

Explicitly attempt to falsify the strategy:
- Does performance disappear after creator/early-holder and wallet-cluster controls?
- Are attention features available too late to trade?
- Does the edge disappear after realistic costs or failed-fill assumptions?
- Are results carried by one token, one launch venue, one time window or a few extreme winners?
- Does the signal only work for surviving tokens?
- Does the signal predict a price move but fail to provide an executable exit?

## 10. Metrics and uncertainty

Report, at minimum:
- Eligible, excluded, rejected and missing samples with denominators.
- Precision/recall and PR-AUC for rare-event classification; calibration by token-age/liquidity strata.
- Net expectancy per attempted trade and per filled trade, after all modeled costs.
- Net return, drawdown, tail loss, turnover, exposure and exit-infeasible rate.
- Fill rate, failed transaction rate, median/p95 execution delay and realized slippage.
- Results by token age, initial liquidity, venue, volatility regime and market period.
- Incremental metrics versus every baseline, with uncertainty intervals.

Use block or clustered resampling that respects time dependence and repeated token/pool episodes. Show raw counts and confidence intervals, not only a point estimate or a single Sharpe ratio. Correct for multiple comparisons when many features or thresholds are tested.

## 11. Pre-registered promotion gates

No feature or model advances because its chart looks good. Before opening the final holdout, document exact numeric thresholds for:
- Minimum usable sample size and coverage by key strata.
- Maximum missingness and collector-latency limits.
- Minimum incremental net expectancy versus the strongest simple baseline.
- Uncertainty interval required for the primary net-performance metric.
- Maximum drawdown, tail-loss and exit-infeasible rates.
- Maximum sensitivity to cost and latency stress.
- Minimum prospective shadow duration and event count.

These numeric values are intentionally **not invented in this document**. Set them using the observed data scale, operational constraints and risk budget, then freeze them before holdout evaluation. Failure to set them in advance blocks a pass.

## 12. Prospective shadow phase

After historical validation, freeze code and configuration and run a prospective shadow period. Record decisions using only information available at the time, quote/submit/fill simulations, vetoes, missed opportunities and data outages. Do not tune on shadow outcomes and then report the same period as independent validation. Any change resets the affected evaluation period.

## 13. Decision states

- `BLOCKED_DATA_QUALITY`: chronology, coverage or collector integrity is insufficient.
- `REJECTED_NO_INCREMENTAL_EDGE`: features fail against simple baselines.
- `REJECTED_AFTER_COSTS`: apparent predictive value does not survive executable costs.
- `REJECTED_NOT_ROBUST`: edge depends on a narrow cohort, outliers or weak controls.
- `SHADOW_ONLY`: historical gates pass but prospective evidence is incomplete.
- `ELIGIBLE_FOR_SEPARATE_RISK_REVIEW`: every preregistered gate passes; this is not automatic authorization for live trading.

## 14. First implementation milestone

Build a data-contract validator and point-in-time snapshot builder before a predictive model. Minimum tests:
- Reject any feature with `feature_ready_ts > decision_ts`.
- Reject or quarantine impossible event ordering.
- Prove that future events cannot alter a previously materialized snapshot.
- Preserve rejected/dead tokens and explicit missingness.
- Ensure train/validation/holdout token episodes and label windows do not leak.
- Reproduce the same snapshot and feature hashes from the same raw data and code commit.
- Test cost calculations and exit-infeasible handling with deterministic fixtures.

Deliverable for this milestone is a reproducible evaluation dataset and report of coverage/data gaps, not a buy/sell bot or a claim of profitability.
