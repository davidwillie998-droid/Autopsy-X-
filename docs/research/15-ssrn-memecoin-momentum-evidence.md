# SSRN Evidence Map: Autopsy-X Memecoin Momentum Intelligence

Review date: 2026-10-11. Scope: Solana-first memecoin discovery, momentum ranking, manipulation resistance, risk, and point-in-time validation.

This is a structured first-pass review, not a claim that every SSRN paper has been discovered. SSRN includes working papers at different stages of review; no paper result is treated as proven for this engine until replicated on our own survivorship-aware data.

## Main conclusions

1. Momentum needs context. Research finds both momentum and reversal, with behaviour changing by horizon, liquidity, size and regime.
2. Volume and attention can be fabricated. A spike in transactions or mentions is not independent demand by itself.
3. Wallet clusters are probabilistic. Related funding and coordinated timing are evidence, not proof of common ownership.
4. Liquidity must be executable. TVL or quoted price alone does not establish the cost or feasibility of exiting.
5. Backtests are easy to overfit. The system needs point-in-time data, dead-token inclusion, chronological validation, cost-aware fills, and a frozen final test.
6. Missing evidence must reduce confidence or block a signal. Never silently convert missing values into zero, and never let a score override a safety veto.
7. The repository's Phase 3C run is reproducible but operationally weak: the recorded plan is 3,000 seconds with 60-second cycles, while actual elapsed time is about 5,616 seconds, with only 2 cycles, 621 exchanges and 40 request errors. Hash reproducibility proves repeatability of the stored artifacts, not market coverage or profitability.

## SSRN research corpus and implementation implications

### Memecoin-specific manipulation and bubbles

- **Ding, Lin, Luo & Xu, “Decompose Market Manipulation Strategies: Evidence from On-chain Meme Coin Market.”** [SSRN 5953738](https://papers.ssrn.com/sol3/papers.cfm?abstract_id=5953738). Uses on-chain and comment data for 6,000 Pump.fun coins to examine concealed accumulation/sniping, wash trading and comment bots. Implement: concentration, coordinated-wallet, round-trip and fake-attention detectors. Working-paper/sample-specific evidence; replicate.
- **Li, Shin, Sun & Wang, “The Dark Side of Decentralized Finance: Evidence from Meme Tokens.”** [SSRN 4228920](https://papers.ssrn.com/sol3/papers.cfm?abstract_id=4228920). Studies competition for attention across meme keywords, issuance and exit scams. Implement: narrative saturation and copycat-token monitoring. Older ecosystem; revalidate.
- **Wei, Li, Chen & Dong, “Memecoin bubbles: resale option or extrapolative demand?”** [SSRN 7350326](https://papers.ssrn.com/sol3/papers.cfm?abstract_id=7350326). 2026 working paper examining turnover and heterogeneous beliefs; abstract reports evidence consistent with extrapolative demand. Implement: treat turnover acceleration as both momentum and potential exhaustion. Review full method before use.
- **Aliyev, Allahverdiyeva & Putniņš, “Scam Alert: Can Cryptocurrency Scams Be Detected Early?”** [SSRN 4490180](https://papers.ssrn.com/sol3/papers.cfm?abstract_id=4490180). Proposes an early scam index for DEX tokens and studies hard/soft rug pulls. Implement: test a pre-trade risk score built from observable liquidity, holder/creator behaviour and transaction features; evaluate precision/recall by token-age cohort. The paper's reported base rates come from its own sample and must not be copied as a Solana-specific prevalence estimate.
- **Krause, “Risks of Investing in Meme Coins: A Case Study of the $TRUMP Coin.”** [SSRN 5126056](https://papers.ssrn.com/sol3/papers.cfm?abstract_id=5126056). Case study of concentration, transparency and insider advantage. Implement: early-holder inventory and creator exposure.
- **Krause, “Beyond the Milei $LIBRA Scandal.”** [SSRN 5149323](https://papers.ssrn.com/sol3/papers.cfm?abstract_id=5149323). Discusses insider advantage and manipulation. Implement: event-timed risk tracking; publicity alone is not a buy signal.

### Momentum, reversals, and cross-sectional ranking

- **Fieberg et al., “A Trend Factor for the Cross-Section of Cryptocurrency Returns.”** [SSRN 4601972](https://papers.ssrn.com/sol3/papers.cfm?abstract_id=4601972). Multi-horizon price-volume trend factor on 3,000+ coins. Implement: compare multi-horizon price/volume features with simple baselines.
- **Huang, Sangiorgi & Urquhart, “Cryptocurrency Volume-Weighted Time Series Momentum.”** [SSRN 4825389](https://papers.ssrn.com/sol3/papers.cfm?abstract_id=4825389). Tests volume-weighted time-series momentum. Implement: test incremental value of volume weighting after costs.
- **Wen, Bouri, Xu & Zhao, “Intraday Return Predictability in the Cryptocurrency Markets: Momentum, Reversal, or Both.”** [SSRN 4080253](https://papers.ssrn.com/sol3/papers.cfm?abstract_id=4080253). Finds momentum and reversal depend on jumps, liquidity and market conditions. Implement: regime-conditioned signals.
- **Fičura & Colak, “Impact of Size and Volume on Cryptocurrency Momentum and Reversal.”** [SSRN 4378429](https://papers.ssrn.com/sol3/papers.cfm?abstract_id=4378429). Reports size/liquidity-dependent dynamics and information in distance from recent highs. Implement: age/liquidity-conditioned momentum and extension risk.
- **Han, Kang & Ryu, “Momentum in the Cryptocurrency Market: A Comprehensive Analysis under Realistic Assumptions.”** [SSRN 4675565](https://papers.ssrn.com/sol3/papers.cfm?abstract_id=4675565). Warns realistic liquidation and fat tails can turn positive mean returns into losses; reports stronger time-series than cross-sectional momentum in its sample. Implement: prioritize net returns, exits and tail risk.
- **Drogen, Hoffstein & Otte, “Cross-sectional Momentum in Cryptocurrency Markets.”** [SSRN 4322637](https://papers.ssrn.com/sol3/papers.cfm?abstract_id=4322637). Studies 30-day winners and subsequent 7-day performance. Implement: keep cross-sectional ranking as a hypothesis, not a universal rule.
- **Filippou, Rapach & Thimsen, “Cryptocurrency Return Predictability: A Machine-Learning Analysis.”** [SSRN 3914414](https://papers.ssrn.com/sol3/papers.cfm?abstract_id=3914414). Out-of-sample analysis of network, momentum, technical and online-activity predictors. Implement: require ML to beat simple baselines out of sample.

### Social attention and influencer signals

- **Maître, Weigert & Pugachyov, “Twitter-Based Attention and the Cross-Section of Cryptocurrency Returns.”** [SSRN 5010136](https://papers.ssrn.com/sol3/papers.cfm?abstract_id=5010136). Abnormal post counts versus a 30-day baseline associate with contemporaneous and next-day returns; investor ticker posts differ from official-channel posts. Implement: abnormal attention and source type separately.
- **Cookson, Lu, Mullins & Niessner, “The Social Signal.”** [SSRN 4241505](https://papers.ssrn.com/sol3/papers.cfm?abstract_id=4241505). Reports attention and sentiment contain different information. Implement: separate volume of attention from sentiment.
- **Merkley, Pacelli, Piorkowski & Williams, “Crypto-Influencers.”** [SSRN 4412017](https://papers.ssrn.com/sol3/papers.cfm?abstract_id=4412017). Studies about 36,000 tweets from 180 influencers and reports initial positive returns followed by negative longer-horizon returns. Implement: source credibility, promotion/conflict flags and reversal tracking.
- **Ante, “How Elon Musk’s Twitter Activity Moves Cryptocurrency Markets.”** [SSRN 3778844](https://papers.ssrn.com/sol3/papers.cfm?abstract_id=3778844). Event-study evidence for short-term price/volume reactions that vary by asset and tweet. Implement: timestamped events and decay tests.
- **Ghimire & Liu, “Trump and his Truth: The effect of viral social media engagement on cryptocurrency returns.”** [SSRN 6628864](https://papers.ssrn.com/sol3/papers.cfm?abstract_id=6628864). 2026 event study of engagement and $TRUMP. Implement: test event type, not only raw engagement. Recent, token-specific working paper.

### Wallet behaviour and DEX execution

- **Félez-Viñas, Johnson & Putniņš, “Insider trading in cryptocurrency markets.”** [SSRN 4184367](https://papers.ssrn.com/sol3/papers.cfm?abstract_id=4184367). Blockchain analysis around exchange listings finds systematic pre-announcement trading. Implement: abnormal accumulation around known events; do not assume listing results transfer to permissionless launches.
- **Makarov & Schoar, “Blockchain Analysis of the Bitcoin Market.”** [SSRN 3942181](https://papers.ssrn.com/sol3/papers.cfm?abstract_id=3942181). Builds entity-linked blockchain data and studies network structure and ownership concentration. Implement: concentration and network exposure features with explicit attribution confidence. Bitcoin entity mapping is not directly portable to Solana.
- **Aldridge, “Synthetic KYC: Detecting Irregularities and Money Laundering on Blockchains.”** [SSRN 4856062](https://papers.ssrn.com/sol3/papers.cfm?abstract_id=4856062). Wallet association/classification methods. Implement: multi-edge wallet graphs with confidence and coverage. Association is not identity proof.
- **Chemaya et al., “The Power of Default: Measuring the Effect of Slippage Tolerance in Decentralized Exchanges.”** [SSRN 4585229](https://papers.ssrn.com/sol3/papers.cfm?abstract_id=4585229). DEX slippage tolerance research. Implement: executable price impact at target order size, not just TVL.
- **“Price Discovery in Constant Product Markets.”** [SSRN 4582649](https://papers.ssrn.com/sol3/papers.cfm?abstract_id=4582649). Studies AMM price discovery and arbitrage/MEV. Implement: account for pool curve, transaction ordering and adverse execution. Not all Solana pools share one design.

### Backtesting and data leakage

- **Bailey et al., “The Probability of Backtest Overfitting.”** [SSRN 2326253](https://papers.ssrn.com/sol3/papers.cfm?abstract_id=2326253). Implement: log all trials and quantify selection risk.
- **Bailey et al., “Pseudo-Mathematics and Financial Charlatanism.”** [SSRN 2308659](https://papers.ssrn.com/sol3/papers.cfm?abstract_id=2308659). Repeated strategy search can produce spurious backtests. Implement: freeze final holdout and report all configurations tried.
- **Wang & Ruf, “Information Leakage in Backtesting.”** [SSRN 3836631](https://papers.ssrn.com/sol3/papers.cfm?abstract_id=3836631). Implement: chronological splits, point-in-time features and purge overlapping labels.
- **Arnott, Harvey & Markowitz, “A Backtesting Protocol in the Era of Machine Learning.”** [SSRN 3275654](https://papers.ssrn.com/sol3/papers.cfm?abstract_id=3275654). Implement: preregister hypotheses, benchmark simple models and preserve untouched test data.
- **Joubert et al., “The Three Types of Backtests.”** [SSRN 4897573](https://papers.ssrn.com/sol3/papers.cfm?abstract_id=4897573). Implement: walk-forward tests, resampling and Monte Carlo stress tests.

## Code workstream: priorities

1. **Acquisition reliability.** The Phase 3C archive at intel/datasets/phase3c/runs/p3c-sol-20261004f/run.json records 3,000 seconds planned, 60-second cycle target, about 5,616 seconds actual elapsed, 2 polling cycles, 621 exchanges and 40 errors. It also contains 91 tokens, 5,629 provider bars, 4,284 swaps and 657 Phase 3A observations. runner_verify.json reports reproducible canonical hashes. Repeatability does not prove adequate coverage.
2. **Measure before patching.** Current hypothesis: the run timer includes universe selection/backfill/enrichment and each polling cycle makes many serial requests; throttling, retries and circuit cooldowns may dominate. This is not a confirmed root cause. Add per-stage/per-provider timing before altering retry semantics.
3. **Coverage-aware status.** Distinguish COMPLETE, COMPLETE_WITH_GAPS, TIMED_OUT and BLOCKED. Record intended/completed cycles, per-provider latency, retries, 429s, circuit waits, pagination gaps and field missingness.
4. **Regression tests.** Use fake clocks/providers for slow endpoints, repeated 429, open circuit, timeout, partial backfill and zero selectable pools. Verify run budgets and no silent loss of required fields.
5. **Feature validation.** Compare no-signal, price-only, price+volume and full system. Measure incremental value by module and cohort. Keep missing data as explicit status; block signals when critical fields are missing.
6. **Manipulation-resistant momentum.** Evaluate unique buyers, net inventory change, wallet concentration, linked funding, round trips, synchronized trades and social bursts against independent on-chain activity. Use multiple pieces of evidence and confidence-weighted flags.
7. **Executable liquidity.** Model buy/sell impact at target size, fees, priority fees, latency, failed exits, LP withdrawal and pool type. Reject candidates whose exit cannot be conservatively estimated.
8. **Leakage-resistant backtesting.** Preserve dead tokens; reconstruct what was knowable at each time; use chronological train/validation/test, purge overlapping outcomes, freeze final test, correct for multiple trials, and include realistic net fills and tail losses.
9. **Paper mode before any live use.** Log predictions only; compare expected versus executable prices and realized outcomes. No live orders until data coverage, operational reliability, net performance and drawdown gates are predeclared and passed.

## Governance

For every paper-derived change, store the citation, version/date, hypothesis, feature mapping, test and kill criterion. Label each claim replicated, partially replicated, not replicated or untested on our data. Never copy published thresholds or return claims into production defaults without replication. Expand this bibliography through targeted SSRN searches on Solana AMMs, wallet common-control inference, launchpad cohorts, rug-pull classification and survivorship-aware token universes. This first map is not exhaustive.


## Deep-research update (2026-10-11): early detection, lead time, and new SSRN evidence

This update prioritizes the actual objective: detect a credible move while it is still actionable, not merely classify a token as a future winner. New SSRN results below are working-paper evidence, not established production facts. Search-result abstracts were reviewed; where the full paper or underlying data were not independently inspected, the claims remain provisional.

### Additional SSRN papers and what they change

- **Zhang & Makgolo, “Cross-Sectional Dispersion and the State Dependence of Cryptocurrency Momentum.”** [SSRN 6648082](https://papers.ssrn.com/sol3/papers.cfm?abstract_id=6648082). The authors report that lagged cross-sectional dispersion predicts weaker subsequent momentum after controls for Bitcoin volatility and average correlation, with a nonlinear effect in the upper tail. Their universe is reconstructed with survivorship-aware screens. **Research hypothesis:** add market-wide cross-token return dispersion as a regime/risk feature; test whether high dispersion should reduce alert confidence, shorten holding expectations, or tighten risk limits. Do not treat the paper's reported effect as validated for launchpad tokens.
- **Tuzcuoglu, “Hidden in the Aggregate: Category-Level Social Media Signals.”** [SSRN 7228018](https://papers.ssrn.com/sol3/papers.cfm?abstract_id=7228018). On Bitcoin Twitter data, category-level attention/sentiment is reported to reveal short, event-aligned associations that aggregate indices can average away; the abstract reports more return-relevant detections after correcting for multiple tests. **Research hypothesis:** classify social posts by intent (ticker mention, trade call, project announcement, meme/narrative, news, bot-like promotion) and test category-specific signals separately. This is Bitcoin/Twitter evidence, not direct proof for Solana meme-token X/Telegram signals.
- **Tarantelli, Marino, Naviglio & Lillo, “Predicting the success of new crypto-tokens: the Pump.fun case.”** [SSRN 6543715](https://papers.ssrn.com/sol3/papers.cfm?abstract_id=6543715). The abstract describes predicting bonding-curve graduation using SOL locked plus structural/behavioral features. The SSRN record is only one page, so evidence details and validation cannot be judged from the abstract alone. **Research hypothesis:** for launchpad tokens, model graduation probability as a separate event from post-graduation return. Graduation is a milestone, not proof of a profitable trade or safe exit.
- **Arefev, “Cross-sectional Momentum in Cryptocurrency: A Net-of-Costs Replication on Tradable Binance Perpetuals (2020-2026).”** [SSRN 7404139](https://papers.ssrn.com/sol3/papers.cfm?abstract_id=7404139). This recent independent working paper reports that two pre-committed momentum specifications lose statistical distinction after realistic costs in its tradable perpetual-futures universe. **Research implication:** gross signal quality is not the objective; net executable opportunity is. It is a different venue and asset universe from Solana spot memecoins, so use as a warning and test design template, not direct evidence of Solana performance.
- **Kamat, “Do Two On-Chain Observation Pipelines See the Same Tokens? Cross-Pipeline Coverage on the Solana pump.fun Launchpad.”** [SSRN 7128818](https://papers.ssrn.com/sol3/papers.cfm?abstract_id=7128818). Compares token-mint coverage from two separately configured observation pipelines. **Research implication:** measure discovery coverage and overlap explicitly; a detector's apparent success may be conditional on what its data pipeline happened to observe. The record describes a single research programme and should be treated as a preliminary dataset-specific result.
- **Kamat, “RED-REJECT-2026-v1: A 96-Day Public Corpus of Algorithmic Filter Rejections…”** [SSRN 7129798](https://papers.ssrn.com/sol3/papers.cfm?abstract_id=7129798). The abstract reports 716,762 records across 4,635 token mints and a collection gap of roughly three weeks. **Research implication:** rejected candidates are essential for counterfactual evaluation: measure whether filters avoid losers or simply reject the biggest winners. Before using the corpus, verify the downloadable files, schema, timestamps, token identity, gaps, and reproducibility; do not assume the abstract's dataset counts establish data quality.
- **Kamat, “Hour-Aware Adaptive Risk Management for Autonomous Memecoin Trading on Solana DEXs.”** [SSRN 6564803](https://papers.ssrn.com/sol3/papers.cfm?abstract_id=6564803). Describes a 15-day paper-traded deployment and asks whether hour-of-day, filter stacks, and small-sample statistics are robust. **Research implication:** time-of-day effects and stacked filters must be tested against counterfactuals, not assumed. A 15-day deployment is too short to establish robust profitability across rare tail events.
- **Mercik & Bedowska-Sojka, “When Markets Never Sleep: Intraday Liquidity Patterns and Volatility Effects in Cryptocurrency Trading.”** [SSRN 6401099](https://papers.ssrn.com/sol3/papers.cfm?abstract_id=6401099). On BTC/ETH exchange data, the abstract reports volatility as a primary driver of spread variation, with time-of-day adding explanatory power. **Research implication:** estimate execution cost conditional on volatility and time, but do not copy centralized-exchange intraday patterns to Solana AMMs without testing.
- **Brauneis, Mestel, Riordan & Theissen, “How to Measure the Liquidity of Cryptocurrencies?”** [SSRN 3503507](https://papers.ssrn.com/sol3/papers.cfm?abstract_id=3503507). Published research comparing lower-frequency liquidity measures against high-frequency benchmarks. **Research implication:** use low-frequency proxies only after calibrating them against actual trade-size-sensitive execution in the target venue; quoted liquidity is not equivalent to executable exit capacity.

### Synthesis: the move-catching problem is a sequential decision problem

The engine should estimate at each decision timestamp:

1. **Move probability:** probability that the token reaches a predeclared forward-return/price-excursion target within horizon H, using only information available at timestamp t.
2. **Time-to-move distribution:** probability of the target being reached within multiple windows (for example, 1, 5, 15 and 60 minutes), rather than a single undifferentiated label.
3. **Adverse excursion and failure risk:** probability and expected size of a drawdown before the target, plus rug/liquidity failure risk.
4. **Executable net opportunity:** expected exit value after price impact, fees, priority fees, failed-transaction allowance, latency and conservative liquidation assumptions.
5. **Data sufficiency:** whether the inputs are fresh and complete enough for this estimate to be trusted.

A high predicted probability is not enough. An alert is actionable only if the expected move is still ahead of us, expected net reward is large enough relative to adverse excursion and costs, and the exit is plausibly executable.

### Proposed signal state machine

- **OBSERVE:** token discovered; required data still being collected.
- **WATCH:** abnormal activity detected, but independent confirmation is insufficient.
- **EARLY_SETUP:** multiple independent features align, the signal is still early relative to the move, and safety gates pass.
- **CONFIRMED_MOMENTUM:** price/flow continuation confirms the hypothesis, but late-entry and extension checks still apply.
- **EXHAUSTION_RISK:** abnormal extension, concentrated ownership, declining net buyer participation, aggressive sell pressure, or deteriorating liquidity.
- **REJECT / DATA_BLOCKED:** manipulation/risk veto or critical data gaps.
- **EXPIRED:** the setup's validity window elapsed without confirmation.

State transitions must be timestamped and auditable. A later confirmation must not be backdated to the first weak signal. Alert latency should be measured from the earliest time the qualifying evidence was actually available, not from a retrospectively inferred event time.

### Feature families to test independently

- **Price/flow:** short-horizon returns, acceleration, range expansion, breakouts relative to recent highs, buy/sell imbalance where reliable, unique active buyers, net buyer participation and follow-through.
- **Volume quality:** volume relative to token-age and time-of-day baselines; transaction count and volume are separate features; detect repetitive same-size trades, rapid round trips, self-trading-like patterns and concentrated counterparties where observable.
- **Liquidity/execution:** pool reserves and curve shape, expected price impact at fixed order sizes, spread/proxy spread, liquidity changes, pool/LP control risk, route availability, failed quote/transaction rate and end-to-end observation delay.
- **Wallet graph:** holder concentration, early-buyer concentration, shared funding sources, synchronized entry/exit, creator-linked wallets and net inventory changes. Treat links as probabilistic, never as identity certainty.
- **Attention:** abnormal attention versus a token-age-aware baseline, author diversity, original posts versus reposts, message category, bot-like repetition, promotion disclosures, source credibility and attention-to-price lead/lag.
- **Regime:** cross-sectional return dispersion, broad crypto moves, SOL/market regime, volatility and liquidity regime. Validate incremental predictive value, not just correlation.
- **Safety:** mint/freeze authority and token controls where applicable, creator/insider concentration, liquidity withdrawal risk, holder distribution, suspicious transfers, and missing or stale safety fields. The chain's actual token/pool mechanics must be checked; not every token uses the same controls.

No single feature family should be allowed to manufacture confidence on its own. Correlated features (e.g. volume, trade count and social mentions generated by one campaign) should not be treated as independent confirmations.

### Evaluation contract for “catch the move at the right time”

Freeze these definitions before testing, then report them by token age, liquidity tier, venue/launch mechanism, volatility regime and alert state:

- **Lead time:** target-event timestamp minus first eligible alert timestamp. Report median and distribution, not only mean.
- **Actionable lead time:** lead time minus the system's actual data/decision/transaction latency. A positive retrospective lead that disappears after latency is not actionable.
- **Precision at horizon:** share of alerts followed by the predefined target within H, after costs and risk filters.
- **Recall of qualifying moves:** share of qualifying events alerted before the last acceptable entry point.
- **Missed-opportunity rate:** qualifying events missed by the detector, including assets excluded at discovery.
- **False-alert burden:** alerts per hour/day and false positives per 100 alerts, because an accurate detector can still be unusable if it floods the operator.
- **Net outcome and downside:** net returns under conservative fills, maximum adverse excursion, tail loss, failed exits, rug/zero-recovery events and drawdown.
- **Coverage:** proportion of the eligible universe actually observed at the needed cadence; report pipeline-specific blind spots.
- **Calibration:** whether events predicted at probability p occur at approximately frequency p, measured out of sample.
- **Baseline lift:** improvement versus simple price-only, volume-only, random-within-cohort, and no-trade baselines.

For a target event, define entry and exit assumptions before running the backtest. Use event labels such as “target hit before stop within H” or a fixed-horizon net return; do not choose the label after seeing which produces the best result. Prevent overlapping labels from leaking across splits. Keep dead, rugged, unlisted and unobserved tokens in the denominator where eligibility rules say they belong.

### Priority experiments

1. **Signal lead-time benchmark:** replay historical streams in strict event-time order; compare price-only, price+volume, price+wallet-flow, price+attention, and full safety-gated models. Measure how early each model fires and how many bad alerts it introduces.
2. **Rejected-token counterfactual:** retain every filter rejection and measure post-rejection outcomes at fixed horizons. This identifies filters that block dangerous tokens versus filters that block winners.
3. **Acquisition coverage audit:** quantify eligible tokens seen, late discoveries, stale observations, missing fields, polling-cycle completion and cross-provider disagreement. A model cannot catch a move that the collector observes too late.
4. **Execution-aware replay:** calculate trade-size-dependent buy and sell impact with latency and adverse movement during execution. Use conservative assumptions for failed sells and sudden liquidity loss.
5. **Regime conditioning:** test dispersion and volatility as separate variables, interactions and nonlinear terms; compare out-of-sample performance against simpler thresholds.
6. **Social signal falsification:** test whether attention precedes price, follows price, or both; deduplicate copied posts and test whether attention adds information after price/volume are known.
7. **Calibration and drift:** track alert probabilities, feature distributions, provider health and performance by cohort; degrade to WATCH or DATA_BLOCKED when coverage or calibration deteriorates.

### Research integrity and source-quality notes

SSRN is a repository, not a guarantee of peer review. Give higher initial weight to papers with transparent methods, credible affiliations, accessible data/code, independent replication and relevant venue/universe; treat single-author deployment notes and newly posted abstracts as idea generators until independently reproduced. Do not rank a paper highly just because it is recent or directly mentions Pump.fun. The direct Solana literature is especially vulnerable to short observation windows, token-selection bias, collection gaps, survivorship bias, and publication/strategy-selection bias.

### Immediate engineering decision

The Phase 3C protocol explicitly freezes collector code. Do not change it inside this research PR. The Phase 3C archive E log states the enrichment pass consumed the duration budget before any polling cycle ran, and archive F changed request parameters in advance to keep enrichment inside the budget. Therefore the next acquisition task is **instrumentation and protocol-compliant validation**, not a speculative retry tweak: record stage timings, first-poll start time, cycle completion, per-provider latency/error/retry/cooldown, observation freshness and missingness. Preserve frozen archive evidence; implement any production change only in a separate, reviewed phase with regression tests and a predeclared protocol.

**Current status:** these are literature-derived hypotheses and a proposed validation contract. No new feature has yet been demonstrated to improve Autopsy-X lead time or profitability on the repository's own data.
