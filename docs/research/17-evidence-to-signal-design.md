# Evidence-to-Signal Design: Solana Memecoin Early Warning

**Status:** research-backed design proposal; not a profitability claim and not authorization for live trading.  
**Review date:** 2026-10-23  
**Scope:** standalone Solana memecoin intelligence, with a 15-minute primary prediction horizon. Keep this work separate from the AUTOPSY X / XAUUSD MT5 EA.

## Objective

Detect tokens with a credible, still-executable chance of rising over the next 15 minutes, before broad attention arrives. The system must also identify when a move is late, attention is coordinated, liquidity is fragile, or an exit may be infeasible.

The system does **not** assume that positive sentiment predicts a pump. It tests whether timestamped information adds predictive value beyond price/volume and liquidity baselines after realistic costs.

## Primary research reviewed

### R1 — SOLMEMES: Do SPL Token Descriptions and Symbols Have Predictive Power?

- Source: [ACM Digital Library, DOI 10.1145/3789982.3790023](https://dl.acm.org/doi/full/10.1145/3789982.3790023)
- Dataset reported: 8,961 Solana memecoin graduations, March–April 2025; token metadata and minute-level price/trade observations over the first 15 minutes.
- Relevant result: text embeddings showed only modest standalone predictive value; temporal features mattered, and reported performance varied by model and deteriorated after costs. Some variants were not statistically significant.
- Design consequence: token name, ticker, description and narrative embeddings are **candidate features**, never a standalone buy trigger. Compare text-only, temporal-only, and combined models. Use a strict out-of-time split and include fees, slippage and failed execution.
- Transferability caveat: the sample is graduated tokens and a narrow period/venue. It does not represent all launched tokens, dead tokens, or today's full Solana market. Rebuild the evaluation with a survivorship-aware universe.

### R2 — MemeTrans: A Dataset for Detecting High-Risk Memecoin Launches on Solana

- Source: [arXiv paper and code/data references](https://arxiv.org/abs/2602.13480), [project repository](https://github.com/git-disl/MemeTrans)
- Dataset reported: 41,470 tokens that completed launchpad sales and migrated to DEXs, with over 200 million transactions and 122 features covering context, trading activity, holdings, bundle/account relationships and time-series behaviour.
- Relevant result: the paper reports that grouped behavioural and concentration features help detect high-risk launches and that its evaluated models reduce losses in its experimental strategy.
- Design consequence: collect creator/deployer exposure, top-holder concentration, early-buyer concentration, unique traders, buy/sell counts, trade timing, liquidity changes and probabilistic wallet-cluster features. Treat clusters as risk evidence, not proof that wallets share an owner.
- Transferability caveat: its universe is selected for successful migration, which excludes many failures before migration. Reproduce with all discovered candidates, including dead, rejected, unsellable and non-graduating tokens. Independently verify any external dataset and code before training on it.

### R3 — SolRugDetector: Investigating Rug Pulls on Solana

- Source: [arXiv paper](https://arxiv.org/abs/2603.24625)
- Dataset reported: 117 manually labelled confirmed rug-pull tokens from 68 incident reports, plus a larger study of newly issued tokens.
- Relevant result: the study focuses on Solana-specific on-chain transaction and state patterns rather than relying solely on generic token metadata.
- Design consequence: a manipulation/rug-risk layer must be independent of the momentum model and able to veto an otherwise attractive candidate. Track creator/holder actions, liquidity removal, concentration, abrupt flow changes and suspicious coordinated behaviour.
- Transferability caveat: the manually labelled set is small relative to the full token universe and labels can be incomplete. Measure precision/recall, false positives and missed rug events by token-age and venue cohort.

### R4 — Wisdom of the crowd signals: Predictive power of social media trading signals for cryptocurrencies

- Source: [Electronic Markets, 2025, open-access article](https://link.springer.com/article/10.1007/s12525-025-00815-6)
- Dataset reported: more than 28,000 explicit trading signals across 287 cryptocurrencies, extracted from social platforms including X, Reddit, Stocktwits and Telegram.
- Relevant result: explicit buy/sell intent signals were associated with short-term price movements in the study; effects varied by asset and timing, and signal bots were observed. The paper notes the actionable window can be narrow.
- Design consequence: classify posts into explicit trade calls, project/news announcements, general mentions, narrative/meme content, criticism and bot-like promotion. Track unique authors, duplicate/repost rates, source history, engagement velocity and first-seen time. Compare explicit trade calls against generic sentiment and raw mention counts.
- Transferability caveat: results across established cryptocurrencies and multiple platforms do not prove the same effect for newly launched Solana memecoins. A signal may arrive after the price move; first-seen and feature-ready timestamps are mandatory.

### R5 — Deciphering Crypto Twitter

- Source: [ACM Web Science 2024, DOI 10.1145/3614419.3644026](https://dl.acm.org/doi/10.1145/3614419.3644026)
- Dataset reported: approximately 40 million crypto-related tweets, with semantic topic grouping and user/reply/quote network analysis.
- Relevant result: the study reports identifiable discussion clusters and network patterns relevant to coordinated activity and bot analysis.
- Design consequence: social influence should be measured by source diversity and network behaviour, not follower count or raw engagement alone. Flag repeated text, synchronized posting, dense repost rings and sudden low-diversity bursts for down-weighting or review.
- Transferability caveat: the dataset period and broad crypto scope differ from real-time Solana token-specific X feeds. Do not claim that a network flag proves a bot or coordinated manipulation.

### R6 — Existing repository evidence and evaluation contracts

- [SSRN memecoin momentum evidence map](15-ssrn-memecoin-momentum-evidence.md)
- [Point-in-time memecoin evaluation protocol](16-point-in-time-memecoin-evaluation.md)
- [Backtesting methodology](08-backtesting-methodology.md)

These define repository-specific hypotheses, point-in-time data rules, cost-aware fills, risk metrics and walk-forward validation. They remain the engineering contract. Literature results must be translated into falsifiable tests rather than copied as production thresholds.

## Evidence-to-feature map

| Feature family | Evidence-based candidate features | Required comparison |
|---|---|---|
| Price/volume baseline | 1m/5m/15m return, volume acceleration, trade count, volatility, distance from recent high | Price-only vs price + volume |
| Social catalyst | Explicit buy/sell call, source class, mention acceleration, unique-author growth, duplicate rate, engagement velocity, event novelty | Raw mentions vs sentiment vs explicit trade calls vs source-diverse signals |
| Token narrative | Name/ticker/description embeddings, narrative category, copycat similarity | Text alone vs time features vs combined model |
| On-chain demand | Unique buyers, net buy/sell imbalance, buyer breadth, trade-size distribution, wallet cohorts | Aggregate volume vs independent buyer breadth |
| Manipulation / rug risk | Creator/deployer holdings, holder concentration, liquidity removal, clustered funding, synchronized trades, repeated round trips | Momentum model with and without independent risk vetoes |
| Executable liquidity | Pool reserves/depth, estimated buy and sell impact at target size, fees, priority fees, failed-swap/exit risk | Quoted return vs conservatively executable net return |
| Market regime | SOL market return/volatility, cross-token dispersion, token age, time of day, venue/pool type | Pooled model vs predeclared regime and age cohorts |

No feature is considered validated merely because a paper motivates it. Each feature family must show incremental value on our own timestamp-correct data.

## Required event and timestamp contract

Every social, news, on-chain and market event must preserve:

- `event_ts`: source-reported event time, where available.
- `first_seen_ts`: first time our collector observed the event.
- `feature_ready_ts`: time all processing required for the feature completed.
- `decision_ts`: earliest time the strategy is permitted to use it.
- Source identifier/URL or chain signature/slot, provider, payload hash, collector version, and missingness/gap flags.

A feature is usable only if its underlying information was actually available by `decision_ts`. Do not backdate delayed social posts, news, metadata, or provider responses into earlier decisions. If the source cannot establish a trustworthy availability time, exclude it from primary point-in-time results and report it separately.

## Pre-registered evaluation sequence

1. **Coverage gate:** verify the frozen 180-pool universe, 12 pools per 60-second cycle, minimum 85 distinct-token qualification, and six frozen hypotheses H1/H3/H4/H8/H9/H10. Preserve failed and rejected candidates; do not lower thresholds to pass.
2. **Data-quality gate:** report coverage by provider, field and minute; deduplicate events; measure delay, pagination gaps, missingness, outages and clock discrepancies. Do not train when the required sample or time continuity fails.
3. **Event-study gate:** test each event class at realistic observation/decision delay against liquidity- and age-matched controls. Measure lead time, forward 15-minute return, adverse excursion and whether the signal occurs before or after the move.
4. **Ablation gate:** compare price-only; price+volume; social-only; on-chain-only; risk-only; and combined features. Log every configuration and all trial counts.
5. **Walk-forward gate:** chronological training/validation folds with purge/embargo for overlapping labels, followed by one untouched final holdout. Include dead tokens and all rejected candidates.
6. **Economic gate:** simulate latency, AMM price impact, LP/venue fees, priority fees, slippage, failed entries, failed exits and liquidity changes. Report net expectancy, profit factor, drawdown, tail loss, worst trade, 5th-percentile trade return, failed-exit rate and regime breakdown.
7. **Paper gate:** emit timestamped BUY / WATCH / EXIT / NO TRADE decisions without submitting orders. Record expected vs simulated executable price, signal age, confidence calibration, vetoes and realized outcome.
8. **Live gate:** not in scope until data coverage, out-of-sample after-cost edge, execution reliability and predeclared drawdown/risk thresholds pass review. No evidence in this document authorizes live trading.

## Acceptance criteria for any new signal

A proposed signal is accepted only when all of the following are true:

- The underlying source and paper are recorded with date, scope, limitations and a stable URL.
- The feature can be computed from information available by the decision timestamp.
- The feature has a preregistered hypothesis, baseline, ablation and failure/kill criterion.
- Improvement appears in untouched out-of-time evaluation, survives realistic costs and multiple-testing correction, and is not explained by survivorship or late entry.
- Performance is reported by token age, liquidity, venue and market regime; safety-veto and exit-failure rates do not deteriorate beyond predeclared limits.
- Results are reproducible from versioned raw data, code, configuration and dataset hashes.

## Current conclusion

The research supports testing **multi-source, point-in-time signals**: social information may help; token text may contain modest information; on-chain concentration and behaviour can help identify risk. It does **not** establish that our system is profitable, that social media consistently leads price, or that any single feature is a reliable buy signal.

The next engineering priority is a reliable event-driven collector and normalized point-in-time event store for social/news plus market/on-chain events. Until collection and timestamps are proven, model training would risk learning from missing, delayed or future information.

## User-facing signal card contract

The standalone Solana intelligence system uses a compact, evidence-first signal card inspired by the AUTOPSY X signal workflow. This is a presentation contract, not a claim that live signal delivery is already implemented.

Each emitted card must contain:

- **Token identity:** chain, token address/mint, symbol, and pool identifier where available. Never identify a token by ticker alone.
- **Decision:** one of `BUY`, `WATCH`, `EXIT`, or `NO TRADE`, but only where that decision's rules are implemented and tested. Existing engine outputs must not be relabelled to imply unsupported behavior.
- **Horizon and timestamps:** the 15-minute evaluation horizon, decision timestamp, data-as-of timestamp, and signal age.
- **Price evidence:** observed price and source; an entry zone or invalidation level only when a tested rule can derive it from available evidence. Otherwise state `not established`.
- **Liquidity and execution risk:** observed liquidity, estimated price impact/slippage and source freshness. Mark unavailable values as unavailable; never invent them.
- **Rationale:** passed conditions, failed conditions, and the specific evidence supporting each.
- **Risk flags and vetoes:** manipulation/rug-risk indicators, concentration, stale or incomplete data, and any blocking rule.
- **Outcome ledger:** preserve the original signal and its inputs; record the observed 15-minute outcome separately without rewriting the original decision.

### Fail-closed display rules

1. If critical price, identity, timestamp or liquidity evidence is missing or stale, emit `NO TRADE` or suppress the candidate according to the tested rule; do not substitute synthetic demo values.
2. Do not display a numerical confidence as a calibrated probability unless calibration has been measured and validated out of sample.
3. Do not fabricate targets, entry prices, stop levels, upside percentages, or claims of profitability.
4. Keep upside and downside candidates in separate rankings. Returning fewer candidates is preferable to filling a quota with weak evidence.
5. This system is read-only: it may collect public market data and emit signals, but must not sign transactions, access wallet secrets, or submit orders.
6. Live market-data operation is not the same as validated signal performance. Readiness remains unapproved until the data-quality, point-in-time, and out-of-sample gates pass.
