# 15. SSRN Evidence Review and Data-Readiness Gates

**Status:** Research synthesis and proposed validation controls; not a claim of predictive performance.  
**Scope:** Standalone memecoin momentum intelligence. This document does not authorize model training, trading, or integration with the MT5 AUTOPSY X robot.  
**Decision rule:** Preserve all existing Phase 3D token-count, independence, provenance, synchronized-liquidity, and chronological-evaluation requirements. Do not relax a gate to obtain a green status.

## Executive finding

The literature supports studying short-horizon momentum, reversal, on-chain participation, attention, liquidity changes, and manipulation indicators. It does **not** establish that these features provide a profitable, executable edge in newly launched Solana memecoins. Most momentum studies use larger, older, centralized-exchange assets; several manipulation studies use Ethereum/Uniswap or Pump.fun launch cohorts; these populations and market mechanisms are not interchangeable.

The project's immediate problem is therefore evidence availability, not model complexity. The earlier data-readiness audit reported 20,238 OHLCV bars across six archives, only 71 bars with usable liquidity (about 0.35%), 1,088 liquidity snapshots, and zero pools satisfying the existing contiguous 5m/15m/60m coverage checks. Those figures remain the prior known audit result until a new reproducible audit supersedes them. Do not train on that dataset.

## SSRN evidence map

Evidence grades below describe relevance to this system, not a paper's overall academic quality. SSRN working papers may be revised, not peer reviewed, and should be independently replicated before their numerical estimates are used.

| Paper | Main reported finding | Relevance | Limit / implementation consequence |
|---|---|---|---|
| Ding, Lin, Luo & Xu, [Decompose Market Manipulation Strategies: Evidence from On-chain Meme Coin Market](https://papers.ssrn.com/sol3/papers.cfm?abstract_id=5953738) (posted 2025; 6,000 Pump.fun coins) | Uses transaction, wallet, and comment data to study creator-linked accumulation, sniping, wash trading, and comment bots. Reports that fabricated trading/attention can attract participation and redistribute wealth. | **Very high** for Solana memecoin launch dynamics and manipulation-aware move classification. | Treat bot labels as noisy observable patterns, not ground truth of intent. Replicate features against point-in-time on-chain data; never use post-event outcomes to create pre-event features. |
| Kalacheva et al., [Detecting Rug Pulls in Decentralized Exchanges: The Rise of Meme Coins](https://papers.ssrn.com/sol3/papers.cfm?abstract_id=4981529) (2024; Ethereum/Uniswap new tokens) | Develops a model for early rug-pull risk; reports a very high share of newly minted tokens exhibiting scam-like characteristics in its sample. | **High** for a separate liquidity-failure/manipulation risk gate. | Its token universe, chain, sample construction, and scam definition may differ materially from Solana. Do not transplant the reported prevalence or thresholds. |
| Aliyev, Allahverdiyeva & Putniņš, [Scam Alert: Can Cryptocurrency Scams Be Detected Early?](https://papers.ssrn.com/sol3/papers.cfm?abstract_id=4490180) (2023; revised 2024) | Studies scam-like token characteristics and proposes an early scam index across DEX markets. | **High** for risk screening and label design. | Scam proxies are not identical to future negative returns; assess false positives against organic failures and survivorship-complete controls. |
| Fantazzini & Xiao, [Detecting Pump-and-Dumps with Crypto-Assets: Dealing with Imbalanced Datasets and Insiders' Anticipated Purchases](https://papers.ssrn.com/sol3/papers.cfm?abstract_id=4557281) (2023) | Studies rare pump events, high-frequency features, and threshold selection under class imbalance; considers signals before public announcements. | **High** for rare-event labels and alert-threshold calibration. | Centralized-exchange pump announcements are not the same event process as permissionless memecoin launches. Avoid synthetic oversampling as the primary evaluation; preserve natural prevalence in test sets. |
| Han, Kang & Ryu, [Momentum in the Cryptocurrency Market: A Comprehensive Analysis under Realistic Assumptions](https://papers.ssrn.com/sol3/papers.cfm?abstract_id=4675565) (2024; revised 2026) | Finds stronger evidence for time-series momentum than cross-sectional momentum in its studied universe; daily fluctuations, liquidation, skewness, and fat tails materially change profitability conclusions. | **High** for conservative baseline design and tail-aware evaluation. | Not a direct test of minute-level memecoin moves. Report the full return distribution, liquidation/failed-exit risk, and net returns, not mean returns alone. |
| Wen, Bouri, Xu & Zhao, [Intraday Return Predictability in the Cryptocurrency Markets: Momentum, Reversal, or Both](https://papers.ssrn.com/sol3/papers.cfm?abstract_id=4080253) (2022) | Reports both intraday momentum and reversal; patterns vary with jumps, liquidity, and macro events in major cryptocurrencies. | **Medium-high** for explicitly separating continuation from exhaustion/reversal targets. | Sample is BTC/ETH/LTC/XRP, not low-liquidity meme tokens. Treat as motivation for competing hypotheses, not proof of edge. |
| Fracassi & Kogan, [Pure Momentum in Cryptocurrency Markets](https://papers.ssrn.com/sol3/papers.cfm?abstract_id=4138685) (2022) | Describes a momentum effect linked to how rolling 24-hour returns are displayed and interpreted, without new fundamental information. | **Medium** for distinguishing genuine flow persistence from UI/reporting and attention feedback. | Feature definitions must be invariant to arbitrary candle boundaries and rolling-window resets; test sensitivity to sampling frequency. |
| O'Hara, Easley, Yang & Zhang, [Microstructure and Market Dynamics in Crypto Markets](https://papers.ssrn.com/sol3/papers.cfm?abstract_id=5337672) (2025) | Finds liquidity and price-discovery measures help predict price dynamics in five major cryptocurrencies. | **High conceptually** for measuring trade imbalance, price impact, and liquidity state. | Major-coin metrics may be unstable in thin AMM pools. Validate on-chain trade and pool-state data; TVL alone is not executable depth. |
| Maître, Weigert & Pugachyov, [Twitter-Based Attention and the Cross-Section of Cryptocurrency Returns](https://papers.ssrn.com/sol3/papers.cfm?abstract_id=5010136) (2024) | Reports abnormal investor ticker-post attention associated with contemporaneous and one-day-ahead returns in a broad crypto sample. | **Medium-high** for time-stamped attention acceleration as a candidate feature. | Attention is vulnerable to bots, survivorship, sampling bias, and latency. Treat social signals as auxiliary and require independent on-chain confirmation. |
| Ammann, Burdorf, Liebi & Stöckl, [Survivorship and Delisting Bias in Cryptocurrency Markets](https://papers.ssrn.com/sol3/papers.cfm?abstract_id=4287573) (2022) | Shows survivorship/delisting bias can materially distort measured crypto performance; finds no positive one-week momentum relationship in their bias-controlled tests. | **Very high** for the token universe and dead-token archive design. | Never evaluate only tokens still indexed, liquid, or visible today. Keep failed, migrated, rugged, and delisted tokens in the denominator. |
| Bailey et al., [The Probability of Backtest Overfitting](https://papers.ssrn.com/sol3/papers.cfm?abstract_id=2326253) (2015) | Proposes combinatorially symmetric cross-validation to estimate strategy-selection overfitting. | **High** for tracking the number of tried hypotheses and configurations. | PBO/CSCV supplements, not replaces, chronological out-of-sample testing in a non-stationary token market. |
| Wang & Ruf, [Information Leakage in Backtesting](https://papers.ssrn.com/sol3/papers.cfm?abstract_id=3836631) (2022) | Demonstrates that apparently separate train/test sets can still leak information in time-series evaluation. | **Very high** for the project's two-clock, point-in-time architecture. | Every feature must be computed from data actually observable at decision time; split by event time and purge overlapping outcome windows. |

### Evidence synthesis

1. **Momentum is conditional, not universal.** Crypto research reports both continuation and reversal; results depend on horizon, liquidity, jumps, token universe, tail events, and costs. The engine must predict a specified outcome at a specified horizon rather than an undefined “big move.”
2. **Liquidity is both a feature and a feasibility constraint.** A token can show a large marked-price move while offering insufficient depth to enter or exit. A price signal without synchronized pool state cannot support an executable-performance claim.
3. **Observed activity can be fabricated.** Wallet count, swap count, volume, and social mentions should not be treated as independent demand without checking concentration, round trips, creator-linked flows, fresh-wallet patterns, and liquidity-provider changes.
4. **Dead tokens are part of the sample.** Token discovery must be point-in-time and archives must retain failed, vanished, migrated, and delisted tokens. A current provider universe creates survivorship bias.
5. **Rare-event accuracy is deceptive.** Report natural prevalence, precision-recall, alert count per day, lead time, calibration, and false alerts. Accuracy or ROC-AUC alone is not adequate.
6. **No paper supplies a transferable profit guarantee.** Results from BTC, centralized exchanges, Ethereum/Uniswap, or Pump.fun do not prove net-of-costs performance for the system's specific universe and execution route.

## Required Phase 3D acquisition acceptance checks

The checks below are additional explicit reporting requirements, not permission to replace or weaken existing gates.

### A. Universe and independence

- Each acquisition window independently meets the existing minimum of **85 distinct eligible tokens**.
- Persist the full selected-token manifest, pool/mint addresses, chain, discovery source, discovery timestamp, selection stratum, exclusion reason, and universe fingerprint.
- Prove Window A and Window B satisfy the existing independence rule and do not overlap forbidden historical archives.
- Distinguish token count from pool count: multiple pools for one mint must not inflate the distinct-token count.

### B. Synchronized liquidity coverage

For each eligible token/pool and each required 5m, 15m, and 60m interval, report:
- expected bars, observed bars, missing bars, duplicate bars, timestamp gaps, and longest contiguous segment;
- OHLCV, quote/base units, pool reserves or venue-appropriate depth, liquidity snapshots, trade count, buy/sell flow if observable, and provider/source provenance;
- age since pool creation, migration events, pool-address changes, and whether a quoted price is actually sellable at a specified notional;
- coverage by token age and liquidity stratum, not only an aggregate percentage.

A token qualifies only under the existing thresholds and contiguous-data rules. Missing liquidity is **unknown**, not zero and not evidence of safety. Do not forward-fill pool liquidity across a gap or infer historical depth from today's TVL.

### C. Point-in-time and archive integrity

- Preserve raw provider responses and request metadata, including endpoint, query parameters, response time, status, retries, provider limits, and content hash.
- Keep event timestamp (ts) separate from first-seen/ingestion timestamp (seen_ts); historical data without a defensible observation time cannot be treated as instantly available.
- Verify per-window provenance independently. The workflow must fail if either window's provenance check fails; success of one window must not mask failure of the other.
- Verify archive sealing and commit success explicitly. Do not suppress non-zero exit codes with ignored failures or unconditional success fallbacks.
- Re-running the audit against the same immutable archives and code/config fingerprint must reproduce the same counts and classification.

### D. Coverage report required before any model work

Produce a machine-readable audit plus human-readable summary with:
- counts at each funnel step: discovered pools, unique mints, excluded mints by reason, selected mints, data-complete mints, liquidity-qualified mints;
- completeness by interval and age/liquidity cohort;
- number of tokens meeting all existing gates in **each** window;
- provenance and independence results;
- rejected tokens and explicit rejection reasons;
- current classification: PASS, FAIL, or INSUFFICIENT_EVIDENCE, with no implicit promotion.

## Prediction-target work is downstream, but can be specified now

Do not fit model parameters until the acquisition and coverage gate passes. Freeze a target contract before inspecting test-period outcomes:

- **Primary target:** probability that, after a decision timestamp and a realistic entry delay, a token achieves a pre-registered positive move threshold before a pre-registered adverse-move threshold within a fixed horizon.
- **Competing outcomes:** continuation, exhaustion/reversal, liquidity failure/unexecutable exit, and insufficient-observation/censored outcome. Never silently label an unobservable exit as a successful trade.
- **Candidate horizons:** retain the project's existing pre-specified horizons (5m, 15m, 30m, 1h, 4h, 12h, 24h) for descriptive event studies; select one primary prediction horizon in a versioned contract before testing. Do not choose the best horizon after looking at test returns.
- **Baseline:** base-rate forecast first, then existing rules, then simple calibrated logistic model. More complex models must beat these on every required chronological fold, not only aggregate metrics.
- **Evaluation:** chronological walk-forward splits, purge overlapping label windows, embargo the configured gap, natural class prevalence, multiple-testing accounting, calibration (Brier/log loss/reliability), precision at a fixed alert budget, recall, median lead time, and per-regime results.
- **Economic evaluation:** model latency, pool fee, priority fee, slippage at actual notional, failed entry/exit, price impact, and liquidity disappearance. Report gross and net results separately.
- **Promotion:** untouched test evidence, stable performance across folds/regimes, reproducible provenance, and successful execution-feasibility gates. A high score without executable exits is not a pass.

## Immediate engineering sequence

1. Resolve the active/queued acquisition runs and capture their actual terminal status and logs; do not infer success from workflow state alone.
2. Fix the acquisition workflow's error propagation and independent per-window provenance checks if inspection confirms the known shell-masking issue.
3. Acquire and seal both independent windows using the existing configuration and thresholds.
4. Run the full synchronized-liquidity audit and commit the audit artifact with its data/code/config fingerprints.
5. If coverage fails, investigate provider history/retention and obtain a source capable of historical pool-state/liquidity reconstruction. Do not substitute more OHLCV bars for missing liquidity data.
6. Only after coverage passes, freeze the prediction target and evaluation protocol; then run the base-rate and simple-model comparisons.
7. Keep production execution disconnected until data readiness, point-in-time evaluation, cost-aware out-of-sample performance, and paper-execution gates all pass.

## Limitations and interpretation

This is a targeted literature map, not an exhaustive systematic review. The cited papers differ in peer-review status, data source, chain, token universe, sampling frequency, outcome definition, and research design. Reported findings are summaries of abstracts/available records and should be verified against full papers before exact estimates or design choices are adopted. The literature motivates tests; only this project's own reproducible, point-in-time results can pass its readiness gates.
