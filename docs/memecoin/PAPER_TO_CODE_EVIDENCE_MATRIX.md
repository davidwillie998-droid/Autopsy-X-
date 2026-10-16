# Memecoin Momentum Intelligence: Paper-to-Code Evidence Matrix

**Scope:** standalone memecoin intelligence only. This document does not extend AUTOPSY X / XAUUSD functionality and does not authorize live trading.

**Decision rule:** research motivates testable hypotheses; it does not establish predictive edge. Historical readiness remains **FAIL** until the existing 5m/15m/60m eligibility thresholds are met by measured, auditable data. Do not relax thresholds to make the dataset pass.

## Research sources and limits

| Source | Research finding relevant to engineering | What it does *not* prove |
|---|---|---|
| Brauneis et al. (2021), *How to Measure the Liquidity of Cryptocurrency Markets?* [Journal of Banking & Finance](https://www.sciencedirect.com/science/article/pii/S0378426620303022) | Liquidity is multidimensional; spread and price-impact estimators need not measure the same thing. Track several liquidity dimensions rather than treating volume as liquidity. | A CEX liquidity estimator is not automatically valid for thin Solana AMM pools. |
| *Not So Fast: Identifying and Remediating Slow and Imprecise Cryptocurrency Exchange Data* (2023) [Finance Research Letters](https://www.sciencedirect.com/science/article/pii/S1544612322005785) | Timestamp precision and feed delay can bias microstructure estimates. Preserve observation/receive times and measure delay. | Findings on centralized exchange feeds do not quantify delay for our DEX provider. |
| Vasiliauskaite, Lillo & Antulov-Fantulin (2022), *Information Dynamics of Price and Liquidity Around the 2017 Bitcoin Markets Crash* [Chaos](https://doi.org/10.1063/5.0080462) | Price and liquidity analysis requires careful time alignment; mismatched observation times can create misleading or non-causal relationships. | Bitcoin crash dynamics do not prove a memecoin momentum signal. |
| Mongardini & Mei (2025 preprint), *A Midsummer Meme’s Dream* [arXiv:2507.01963](https://arxiv.org/abs/2507.01963) | Reported meme-token market manipulation motivates wash-trading, liquidity-pool and price-inflation risk checks. | Preprint findings are not settled consensus and do not label any specific pool fraudulent. |
| Hu et al. (2026 preprint), *MemeTrans* [arXiv:2602.13480](https://arxiv.org/abs/2602.13480) | Launch context, transaction activity, holder concentration and bundled-account patterns are plausible launch-risk feature families. | Dataset scope/selection may not generalize to every token, venue or time period. |
| Li et al. (2026 preprint), *Catching the Rug* [arXiv:2608.20271](https://arxiv.org/abs/2608.20271) | Early-window data can be evaluated for rug/fraud-risk prediction; cross-platform generalization deserves explicit testing. | Rug-risk classification is a different target from predicting upside or executable returns. |

## Evidence matrix

| Priority / hypothesis | Candidate features and minimum data | Required implementation / test | Failure condition | Acceptance criterion |
|---|---|---|---|---|
| **P0 — Coverage is real, not inferred** | Per-pool OHLCV bars; liquidity snapshots; provider; pool/token IDs; timestamps; eligibility flags; gap/staleness metrics | Build a reproducible per-pool coverage report for contiguous 5m, 15m and 60m windows. Report denominators, exclusions, gaps and freshness. | Missing timestamps/IDs, duplicate bars, snapshots counted as continuous coverage, or aggregate counts hiding pool-level gaps. | Existing thresholds pass for explicitly listed pools with reproducible evidence; otherwise readiness remains FAIL. No threshold changes. |
| **P0 — Features are point-in-time valid** | Event/block time, provider receive time, ingestion time, prediction cutoff, source freshness | Enforce an as-of join: only data observable by prediction time may enter a feature row. Add tests that inject future-dated snapshots/events and ensure they are excluded. | Any future observation leaks into features, or event time is mistaken for the time the system could have known it. | Future-data negative tests pass; every feature row can be reconstructed from records available at its cutoff. |
| **P0 — Liquidity is not just volume** | Pool reserves/liquidity snapshots, trades/OHLCV, quote/base amounts where available, estimated slippage, snapshot age | Keep separate fields for observed liquidity, turnover, price impact/slippage estimate and freshness. Mark unavailable estimates as unknown, never zero. | Volume alone is used as a liquidity proxy; stale/missing liquidity is treated as healthy. | A signal is ineligible when required liquidity evidence is stale or absent; liquidity dimensions and provenance are reported separately. |
| **P1 — Momentum target is explicit** | Timestamped returns over fixed horizons; future high/low; executable quote/price where available | Define the target and horizon before training. Record prediction time, horizon end, threshold and label-generation version. | Ambiguous “big move” label, overlapping labels leaking across chronological splits, or label uses information unavailable at prediction time. | Labels are deterministic and auditable; chronological train/validation/test splits purge overlapping future-label windows. |
| **P1 — Executable opportunity differs from price pump** | Entry-time price/quote, liquidity, estimated trade size, fees, slippage, observation latency and exit price | Evaluate gross price move and net executable return separately; apply conservative execution delay and costs. Include an unavailable/unexecutable outcome. | Backtest assumes fills at candle close/low/high or ignores fees, impact, delay, or failed execution. | Report net outcomes by liquidity cohort and delay; no edge claim based only on chart returns. |
| **P1 — Manipulation/rug risk is separate** | Liquidity changes/removal where observable, holder concentration, bundled-wallet signals, suspicious turnover, pool/token metadata | Maintain a separate risk target and feature namespace; test missing-data behavior and false-positive trade-offs. | Fraud labels are used as momentum labels, or a heuristic is represented as a confirmed fraud finding. | Momentum and risk outputs are separately scored, calibrated and reported; uncertain evidence remains uncertain. |
| **P2 — Generalization is measured** | Chain/venue, pool age, liquidity cohort, launch cohort, calendar time and data-quality cohort | Use strictly chronological out-of-sample evaluation and cohort-level metrics. Compare against simple baselines and report sample sizes. | Random split leaks nearby events/tokens; only winners or complete-data pools are reported; tiny cohorts are presented as robust. | All metrics include sample counts and coverage; performance is compared with baselines and disclosed per cohort. |
| **P2 — Alerts are robust to source failures** | Provider errors, rate limits, data age, cycle timing, missing fields | Test degraded feeds, stale snapshots, duplicate/out-of-order records, rate limits and circuit-breaker recovery. | Provider failure silently becomes zero activity or a high-confidence signal. | Degraded or stale inputs produce an explicit “insufficient data” state, not a confident momentum alert. |

## Required readiness report

Each audit run should publish, at minimum:

1. Run ID, code revision, request/config hash, providers and collection interval.
2. Per-pool eligible bar count and expected interval; duplicate/out-of-order counts; missing intervals and longest gap.
3. Per-pool liquidity-snapshot count, age distribution, stale fraction and source errors.
4. Number of pools passing each **unchanged** 5m, 15m and 60m contiguous-liquidity requirement.
5. Point-in-time join audit: rows checked, future-dated rows excluded, unmatched/stale features and failed assertions.
6. A clear verdict: **FAIL / INSUFFICIENT DATA / PASS**, with reasons. A green workflow means code/tests completed; it is not evidence that the historical dataset is adequate.

## Implementation order

1. **Coverage audit first.** Produce the per-pool report from the acquisition archive and keep the current thresholds fixed.
2. **Causal-time contract second.** Make receive/observed availability timestamps mandatory for point-in-time feature eligibility and add future-data negative tests.
3. **Separate target contracts third.** Define upside/momentum, executable net return and rug/manipulation risk as distinct targets.
4. **Only then evaluate models.** Use chronological splits, purge overlapping label windows, compare simple baselines and report cohort/sample-size uncertainty.

## Stop conditions

- Do not train or describe the system as model-ready while coverage fails.
- Do not loosen liquidity/continuity thresholds to obtain a passing audit.
- Do not claim early-prediction edge from retrospective chart examples alone.
- Do not treat provider-reported data as ground truth without recording its timing, completeness and limitations.
- Do not infer a rug pull or manipulation solely from a heuristic feature.

## References

- Brauneis, A., Mestel, R., Riordan, R. & Theissen, E. (2021). *How to Measure the Liquidity of Cryptocurrency Markets?* Journal of Banking & Finance. https://www.sciencedirect.com/science/article/pii/S0378426620303022
- *Not So Fast: Identifying and Remediating Slow and Imprecise Cryptocurrency Exchange Data* (2023). Finance Research Letters. https://www.sciencedirect.com/science/article/pii/S1544612322005785
- Vasiliauskaite, V., Lillo, F. & Antulov-Fantulin, N. (2022). *Information Dynamics of Price and Liquidity Around the 2017 Bitcoin Markets Crash.* Chaos. https://doi.org/10.1063/5.0080462
- Mongardini, A. & Mei, J. (2025). *A Midsummer Meme’s Dream: Investigating Market Manipulations in the Meme Coin Ecosystem.* Preprint. https://arxiv.org/abs/2507.01963
- Hu, Y. et al. (2026). *MemeTrans: A Dataset for Detecting High-Risk Memecoin Launches on Solana.* Preprint. https://arxiv.org/abs/2602.13480
- Li, Y. et al. (2026). *Catching the Rug: Early Prediction of Fraudulent Memecoins on Solana via Machine Learning.* Preprint. https://arxiv.org/abs/2608.20271


## Engineering finding from the Phase 3D request audit

The request uses `backfill_pages: 0` intentionally. GeckoTerminal returns historical OHLCV but does not provide historical liquidity snapshots. Combining old price bars with a current pool-liquidity snapshot could inflate apparent coverage or introduce look-ahead if the consumer ignores the bar's `seen_ts`. The conservative coverage run therefore does not backfill OHLCV.

**Fix committed:** keep the dedicated Phase 3D polling mode, five-pool stratified universe, one synchronized multi-pool liquidity snapshot plus one five-bar OHLCV request per pool each 60-second cycle, 60-second lag policy, and two-hour live window. A regression test now protects `backfill_pages == 0` and explains the point-in-time rationale.

**What still needs proof:** two hours of configured runtime is not evidence of two hours of valid observations. The new archive must demonstrate enough completed cycles, fresh per-pool liquidity snapshots, eligible price bars, acceptable gaps and valid provenance. Historical readiness remains **NOT VERIFIED** until measured coverage passes the unchanged 5m/15m/60m thresholds. This acquisition cannot reconstruct historical liquidity that was never collected.

## Additional primary research detail

- Foley et al. (2023), *Not so fast*, analyze raw tick data from 17 centralized exchanges and show that timestamp precision and matching-engine differences distort trade-package and liquidity estimates. We apply the general data-quality lesson to receive/observation timing, but do not assume their CEX-specific correction transfers directly to GeckoTerminal or Solana AMMs.
- The 2026 MELT revision of *MemeTrans* describes 41,470 Solana launches and more than 200 million transactions, with typed behavioral traces and bundle-level links between accounts. Its cohort is restricted to launches completing the defined migration lifecycle and a particular market period, so selection bias and cross-period generalization must be tested before transferring its results to our live universe. [MELT v2](https://arxiv.org/html/2602.13480v2).
- Li et al. (2026), *Catching the Rug*, frame rug-pull detection using first-five-minute features to predict one-hour risk labels. Those labels are liquidity-withdrawal / trading-idleness outcomes, not upside-momentum labels. [Paper](https://arxiv.org/html/2608.20271).

**Current decision:** the request preserves point-in-time liquidity integrity and the regression test guards against accidental historical backfill. Historical readiness is still **NOT VERIFIED** until the new acquisition completes, provenance passes, and measured coverage clears the unchanged thresholds.


## Expanded SSRN evidence review (16 October 2026)

This is a targeted, multi-angle literature search, not a claim that 500,000 papers were individually read. SSRN items are working papers unless a separate publication record establishes peer review. Abstract-level evidence is treated as provisional; implementation decisions below rely on methodological convergence and explicit failure cases, not headline returns.

| SSRN paper | Evidence useful to this project | Engineering implication | Transfer limitation |
|---|---|---|---|
| Ding, Lin, Luo & Xu (2025), [Decompose Market Manipulation Strategies: Evidence from On-chain Meme Coin Market](https://papers.ssrn.com/sol3/papers.cfm?abstract_id=5953738) | Uses granular on-chain transactions and off-chain comments across 6,000 Pump.fun meme coins; studies concealed accumulation/sniping, wash trading and comment bots. | Treat apparent activity and sentiment as potentially manipulable. Add provenance-aware wallet concentration, burst/coordinated-account and abnormal turnover features only when source coverage supports them. | Pump.fun cohort and observational associations do not label an individual token fraudulent or predict upside. |
| Kamat (2026), [Hour-Aware Adaptive Risk Management for Autonomous Memecoin Trading](https://papers.ssrn.com/sol3/papers.cfm?abstract_id=6564803) and its [companion dataset](https://zenodo.org/records/23017853) | The disclosed 15-day paper-trading sample has 190 trades; the paper reports that removing the top three trades reverses cumulative profitability. Its hour-of-day comparison is explicitly non-confirmatory (reported p=0.5634), and real slippage/failed transactions/MEV were not measured. | Require fragility analysis, complete outcome distributions, rejected-candidate counterfactual logging and conservative execution costs. Treat small-sample positive returns as descriptive, not proof of edge. | One system, short window and simulated execution; it cannot establish a general strategy or validate our own model. |
| Wang & Pang (2026), [When the Feed Lags: Public-Data Delay and Quoted Liquidity in Crypto Markets](https://papers.ssrn.com/sol3/papers.cfm?abstract_id=6675338) | Minute-level Binance BTC/ETH/BNB evidence links higher public-feed delay to wider spreads and thinner displayed depth, including out-of-sample gains for quoted-spread prediction. | Persist request/response times; report cycle duration, request failures, cadence overruns and snapshot freshness. A stale feed must downgrade eligibility rather than produce a confident alert. | Centralized-exchange order books are not Solana AMM pool snapshots; use this as a testable data-quality hypothesis, not a calibrated DEX model. |
| Foley et al. (2022; later journal publication), [Not So Fast](https://papers.ssrn.com/sol3/papers.cfm?abstract_id=4156263) | Raw tick data across crypto exchanges show that timestamp precision and venue latency can distort liquidity and trading metrics. | Distinguish event time, response/receive time and ingestion time. Reconstruct features only from data available at the decision cutoff. | CEX trade/quote sequencing is not identical to AMM pool-state timing. |
| Alexander & Dakos (2019), [A Critical Investigation of Cryptocurrency Data and Analysis](https://papers.ssrn.com/sol3/papers.cfm?abstract_id=3382828) | Shows that data-source and timestamp inconsistencies can materially change crypto return and index calculations. | Record provider, raw-response hash, schema/parser version, duplicates, missing intervals and revisions. Reproducible provenance is a hard gate. | Older market-data examples; provider-specific issues must be re-tested on our actual feed. |
| Rustin (2026), [Testing for Tradable Alpha in Short-Term Bitcoin Market Data](https://papers.ssrn.com/sol3/papers.cfm?abstract_id=6444920) | Reports weak short-horizon feature correlations that fail to generate positive risk-adjusted results after costs under walk-forward evaluation. | Separate statistical prediction from net executable value. Use cost-aware baselines and pre-register the evaluation horizon/threshold before tuning. | BTC CEX results do not settle the question for early-stage Solana tokens. |
| Kim (2026), [Beyond Accuracy: A Validation Framework for Machine Learning in Cryptocurrency Trading](https://papers.ssrn.com/sol3/papers.cfm?abstract_id=6508779) | Evaluates 340 strategy variants and emphasizes that passing a statistical/permutation test does not guarantee stable validation or economic value. | Use sequential gates: data validity → leakage tests → out-of-sample predictive lift → cost-adjusted economic lift → robustness/fragility. Failure at any gate blocks promotion. | Framework and sample assets may differ; the gate structure is more transferable than its reported empirical results. |
| Zhang et al. (2026), [What Drives Crypto Prices?](https://papers.ssrn.com/sol3/papers.cfm?abstract_id=6482433) | Reports illiquidity predicts the magnitude of intraday moves, not their direction, in major-crypto data. | Treat liquidity/illiquidity primarily as risk, volatility and execution context unless a separate directional hypothesis survives testing. | Major crypto session-level results are not evidence of directional predictability in memecoins. |
| Li, Shin, Sun & Wang (2022), [The Dark Side of Decentralized Finance: Evidence from Meme Tokens](https://papers.ssrn.com/sol3/papers.cfm?abstract_id=4228920) | On-chain meme-token data document the scale of issuance and risks around the low-friction token ecosystem. | Maintain an explicit universe/selection log and include failed, dead and rugged tokens; do not evaluate only tokens that survived long enough to appear in a current listing. | Historical period and chains differ from the present Solana universe. |

## Code change from this review: per-cycle acquisition diagnostics

The previous archive reported a long elapsed run with only two polling cycles. That aggregate result could not show whether time was lost to provider latency, retries/circuit waits, or work within individual polling cycles. The acquisition loop now records `cycle_telemetry` for every completed live cycle:

- start/end timestamps and measured duration;
- configured target cadence and cadence overrun;
- request count and provider-error count for that cycle;
- number of selected pools;
- incremental persistence to `run.json`, so interrupted runs retain completed-cycle diagnostics.

The Fetcher now maintains request/error counters so cycle diagnostics do not need to re-read the entire raw manifest for each cycle. A regression test checks the telemetry shape and basic invariants.

**What this fixes:** the next audit can diagnose whether synchronized polling actually meets its 60-second cadence and whether provider failures explain sparse coverage. It does not create historical liquidity data or make the archive ready by itself.

## Updated evidence gates

1. **Acquisition integrity:** provenance verifies; request/config and code revision are recorded.
2. **Cadence integrity:** cycle telemetry shows actual duration, overrun, requests and errors. Report distributions (median, p95, maximum), not only average cadence.
3. **Coverage integrity:** per-pool synchronized snapshots and closed OHLCV bars meet existing 5m/15m/60m continuity and freshness rules.
4. **Point-in-time integrity:** no observation enters a feature before its receive/ingestion time; future-dated negative tests pass.
5. **Predictive integrity:** pre-specified horizons and labels, chronological out-of-sample testing, purged overlapping labels, simple baselines and permutation controls.
6. **Economic integrity:** include pool-size-dependent price impact, fees, quote/observation delay, failed fills and conservative exit assumptions.
7. **Fragility and manipulation:** report performance excluding top winners, by liquidity/age/venue cohorts, and keep manipulation/rug risk separate from upside labels.

Do not change the coverage thresholds to compensate for poor acquisition cadence. If cycle telemetry shows overruns, reduce unnecessary calls or the universe size and rerun; if it shows provider errors, fix the transport/provider failure. If cadence is sound but snapshots are absent, investigate provider schema/coverage rather than counting price bars as liquidity evidence.

**Status after code change:** telemetry instrumentation is committed and regression coverage is added. CI, acquisition completion, provenance and actual readiness are still separate verification gates; no pass is claimed until their outputs are inspected.
