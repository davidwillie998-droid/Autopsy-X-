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


## Second-pass research (2026-10-11): microstructure, manipulation timing, and survivorship

This pass focuses on what changes before a move, how manipulators can manufacture signals, and whether a backtest observes the universe it claims to study. Abstract-level results remain hypotheses until independently reproduced.

### Additional SSRN papers

- **Fracassi & Kogan, “Pure Momentum in Cryptocurrency Markets.”** [SSRN 4138685](https://papers.ssrn.com/sol3/papers.cfm?abstract_id=4138685). Reports a behavioral “pure momentum” effect arising from predictable changes in displayed rolling 24-hour returns, even without new fundamental information. **Test:** compare fixed, non-overlapping clock-window returns with rolling-24h display changes, to detect mechanical false acceleration.
- **Grobys & Shahzad, “Cryptocurrency momentum: Is it an illusion?”** [SSRN 4633099](https://papers.ssrn.com/sol3/papers.cfm?abstract_id=4633099). Argues that momentum portfolio variance may be heavy-tailed enough to undermine conventional Sharpe/t-statistic interpretation under the paper's assumptions. **Test:** report tail losses, robust inference, median outcomes and top-trade contribution, not Sharpe alone.
- **Fantazzini & Xiao, “Detecting Pump-and-Dumps with Crypto-Assets: Dealing with Imbalanced Datasets and Insiders’ Anticipated Purchases.”** [SSRN 4557281](https://papers.ssrn.com/sol3/papers.cfm?abstract_id=4557281). Uses 30-second data and rolling one-hour features in a historical Binance pump-signal setting, considering early detection and class imbalance. **Test:** use precision-recall, false alerts per day, and lead-time distributions; separate pre-announcement patterns from post-announcement reaction. Venue differs from Solana.
- **Dhawan & Putniņš, “A New Wolf in Town? Pump-and-Dump Manipulation in Cryptocurrency Markets.”** [SSRN 3670714](https://papers.ssrn.com/sol3/papers.cfm?abstract_id=3670714). Studies openly announced pumps, distorted prices, abnormal volume and wealth transfer. **Test:** treat coordinated public pumps as a separate event class, and do not assume the announcement is the earliest information timestamp.
- **Li, Shin & Wang, “Cryptocurrency Pump-and-Dump Schemes.”** [SSRN 3267041](https://papers.ssrn.com/sol3/papers.cfm?abstract_id=3267041). Reports that historical pump episodes can peak within minutes and reverse quickly. **Test:** record alert, peak, reversal and executable exit times rather than end-of-day return alone.
- **Hamrick et al., “The Economics of Cryptocurrency Pump and Dump Schemes.”** [SSRN 3310307](https://papers.ssrn.com/sol3/papers.cfm?abstract_id=3310307). Documents Telegram/Discord pump announcements and finds low-volume obscure coins more susceptible in its historical sample. **Test:** attach source/coordination metadata to social signals; treat thin liquidity as risk, not automatic opportunity.
- **Anastasopoulos et al., “Order Flow and Cryptocurrency Returns.”** [SSRN 5020002](https://papers.ssrn.com/sol3/papers.cfm?abstract_id=5020002). Reports predictive content in global order flow for cross-sectional crypto returns. **Test:** assess whether net-flow features add value beyond price/volume; do not assume global fiat flow maps directly to per-pool Solana flows.
- **Alexander et al., “Order Flow Impact and Price Formation in Centralized Crypto Exchanges.”** [SSRN 4867599](https://papers.ssrn.com/sol3/papers.cfm?abstract_id=4867599). Examines order types and cross-venue price formation, with high-frequency integration weakening at times. **Test:** record source event time and ingestion time; stale data can erase apparent lead. CEX order books differ from AMMs.
- **Vafin, “Order-Flow Imbalance and Short-Horizon Return Predictability in Cryptocurrency Markets.”** [SSRN 6938742](https://papers.ssrn.com/sol3/papers.cfm?abstract_id=6938742). Recent short review/proposal for distinguishing predictive order-flow content from the mechanical effect of trades on price. **Test:** use lagged features and avoid circular same-interval predictors. Treat as a proposed framework, not conclusive evidence.
- **Kamat, “Pump.fun Graduation Regime Windows: Survival Analysis of 832,941 Token Launches and the Social-Presence Effect.”** [SSRN 6915560](https://papers.ssrn.com/sol3/papers.cfm?abstract_id=6915560). The SSRN record includes a corrigendum withdrawing a graduation-threshold sensitivity analysis after direct checks found 0 of 100 sampled mints confirmed graduated. **Use:** verify event labels against authoritative on-chain/program state and inspect corrections; do not use the withdrawn analysis.
- **Kamat, “Do Two On-Chain Observation Pipelines See the Same Tokens?”** [SSRN 7128818](https://papers.ssrn.com/sol3/papers.cfm?abstract_id=7128818). Reports very low overlap between two observation pipelines and notes a major collection gap in one window. **Test:** report eligible-universe coverage, timestamped gaps and pipeline overlap; incomplete windows make raw overlap counts misleading.
- **Kamat, “Hour-Aware Adaptive Risk Management for Autonomous Memecoin Trading on Solana DEXs.”** [SSRN 6564803](https://papers.ssrn.com/sol3/papers.cfm?abstract_id=6564803). Abstract describes 190 paper trades over 15 days; removing the top three trades flips cumulative returns unprofitable, while an exploratory hour-group result is not statistically significant. **Use:** contribution concentration, ablation and longer out-of-sample tests; this is a small author-produced deployment note, not independent validation.
- **Albers et al., “The Price Impact of Nothing: Rejected Orders as Predictors of Future Returns.”** [SSRN 6250378](https://papers.ssrn.com/sol3/papers.cfm?abstract_id=6250378). Studies whether rejected orders/liquidity changes in limit-order-book markets carry information. **Test:** log rejected quotes, failed swaps/routes and failed transactions as separate event types. LOB findings do not prove a Solana edge.
- **Kroner, Mohammed & Vega, “How Do Cryptocurrencies Price Economic News?”** [SSRN 6447644](https://papers.ssrn.com/sol3/papers.cfm?abstract_id=6447644). Reports elevated volatility, volume and spreads around US macro announcements and responses associated with yield/risk-off surprises. **Test:** control for market-wide SOL/BTC impulses so token-specific signals are not credited for broad-market moves.

### Supplementary non-SSRN cross-checks

The project remains SSRN-first. These are additional validation leads, not replacements for the SSRN corpus.

- **MemeTrans: A Dataset for Detecting High-Risk Memecoin Launches on Solana.** [arXiv 2602.13480](https://arxiv.org/abs/2602.13480). Abstract describes 40k+ launches that migrated to DEX, 122 features and bundle-level clues, and reports reduced financial loss in its experimental setup. Inspect inclusion rules, labels, license and temporal split before reuse; a migrated-token sample can omit early failed launches.
- **A Midsummer Meme’s Dream: Investigating Market Manipulations in the Meme Coin Ecosystem.** [arXiv 2507.01963](https://arxiv.org/abs/2507.01963). Abstract describes multi-chain manipulation patterns including wash trading and liquidity-pool-based price inflation. Treat headline rates as sample/label dependent and reproduce before use.
- **Detecting rug pulls in decentralized exchanges: The rise of meme coins.** [Journal article, 2026](https://www.sciencedirect.com/science/article/pii/S2096720925000636). Ethereum DEX study with an exploratory fraud-label definition. Borrow candidate features and audit questions, not its prevalence estimate for Solana.

### New synthesis: three clocks determine whether an alert is early

1. **Market clock:** when the event occurred on-chain (slot/block and transaction order where available).
2. **Collector clock:** when our system first received enough information to identify it.
3. **Decision/execution clock:** when the alert could be emitted and a realistic transaction could reach the venue.

A backtest must never pretend it knew an event at market time if the collector received it later. An apparent lead that disappears after collection and execution latency is not actionable. If price impact consumes the remaining move, predictive accuracy does not create an executable edge.

### Model contract: estimate a path, not just “will it pump?”

At every point-in-time timestamp t, estimate:
- probability a predeclared net-return/price-excursion target is hit before an adverse-excursion threshold within horizon H;
- time-to-target probabilities across several horizons, with right-censoring;
- expected and tail adverse excursion before target or exit;
- sellability and execution impact at a specified trade size;
- data freshness, missingness and provider reliability;
- manipulation risk as a separate calibrated estimate with hard safety vetoes.

A token that rises 100% and collapses before an executable exit is not automatically a successful opportunity. Do not tune target, horizon or stop after seeing the test outcomes.

### Additional experiments

1. **Fixed vs rolling returns:** compare 15s/30s/60s/5m fixed-window returns with rolling-24h display changes.
2. **Lead-lag:** test whether flow, unique buyers, liquidity and social attention lead price after controlling for prior price/volume, avoiding same-interval circularity.
3. **Peak/reversal survival:** estimate time from first eligible alert to local peak and adverse reversal.
4. **Rejected-opportunity counterfactual:** retain every filter rejection and passively track future outcomes, matched by token age, liquidity and time.
5. **Label audit:** verify token creation, migration/graduation, liquidity removal and rug labels against authoritative chain/program state.
6. **Tail stress:** report top-trade contribution, worst 1% outcomes, failed sells and clustered drawdowns; bootstrap by day/cohort rather than treating ticks as independent.
7. **Source robustness:** rerun across providers and windows; log outages, stale feeds and API limits.

### Claim ledger

Mark each paper-derived result **Replicated**, **Partially replicated**, **Not replicated**, **Untested**, or **Not portable**. SSRN presence, recency, sample size and an impressive abstract are not proof of validity. For recent single-author Solana studies, inspect code/data, corrections, gaps, labels and whether metrics are out-of-sample.

### Second-pass SSRN review (2026-10-12): contradiction and failure audit

This pass prioritizes papers that challenge attractive momentum claims, distinguish prediction from tradability, or expose label/coverage failures. SSRN posting is not itself peer review; results below are author-reported and remain hypotheses until independently reproduced.

#### Findings that materially change the research design

- **Nefedov, “How Much Sharpe is Illusory? Quantifying Backtest Overfitting in Crypto Factor Strategies.”** [SSRN 7350238](https://papers.ssrn.com/sol3/Delivery.cfm/7350238.pdf?abstractid=7350238). The abstract reports an audit of six factors on 137 Binance USDT perpetuals over 2020–2024. Full-sample/frictionless selection reportedly inflated annualized Sharpe by 3.6× on average; under the paper's nested walk-forward, transaction-cost and Deflated Sharpe Ratio protocol, none of the six factors survived deflation in its baseline and four had negative out-of-sample Sharpe. **Design consequence:** precommit the small candidate grid, preserve every trial, and report deflated/selection-adjusted evidence. This is a recent working paper in a different market, not a Solana result.
- **Han, Kang & Ryu, “Momentum in the Cryptocurrency Market: A Comprehensive Analysis under Realistic Assumptions.”** [SSRN 4675565](https://papers.ssrn.com/sol3/papers.cfm?abstract_id=4675565). The revised SSRN record reports that liquidation-aware daily fluctuations can turn strategies with positive mean returns into losses; time-series momentum is stronger than cross-sectional momentum in their studied universe. **Design consequence:** use net executable outcome distributions, not average return or ranking accuracy alone.
- **Arefev, “Cross-Sectional Momentum in Cryptocurrency: A Net-of-Costs Replication on Tradable Binance Perpetuals (2020–2026).”** [SSRN 7404139](https://papers.ssrn.com/sol3/papers.cfm?abstract_id=7404139). This recent replication reports that two precommitted momentum specifications were not statistically distinguishable from zero net of costs under three tests across an archived tradable perpetual universe. **Design consequence:** do not assume a cross-sectional momentum rank creates edge; require incremental, out-of-sample lift over simple age/liquidity-aware baselines. Working-paper status and venue differences limit transfer.
- **Bysik & Ślepaczuk, “Machine Learning-Based Bitcoin Trading Under Transaction Costs: Evidence From Walk-Forward Forecasting.”** [SSRN 6795938](https://papers.ssrn.com/sol3/papers.cfm?abstract_id=6795938). The abstract describes about 70,000 hourly BTC/USDT observations and 27 walk-forward folds; sign-based trading reportedly failed at 10 bps costs, while a cost-aware forecast threshold improved selected configurations. The paper also says formal dominance among model classes was not established. **Design consequence:** make expected move exceed estimated round-trip cost plus uncertainty and slippage buffer before issuing an actionable alert; don't select a model from headline returns.
- **Cookson, Lu, Mullins & Niessner, “The Social Signal.”** [SSRN 4241505](https://papers.ssrn.com/sol3/papers.cfm?abstract_id=4241505). Published in the *Journal of Financial Economics* (2024); the authors report that sentiment and attention are distinct, with sentiment predicting positive next-day returns in their setting while attention predicts negative next-day returns. **Design consequence:** never collapse mention volume, sentiment, source credibility and attention acceleration into one “social score.” The direction may differ in permissionless launch markets and must be tested there.
- **Maître, Weigert & Pugachyov, “Twitter-Based Attention and the Cross-Section of Cryptocurrency Returns.”** [SSRN 5010136](https://papers.ssrn.com/sol3/papers.cfm?abstract_id=5010136). In 2018–2022 crypto data, abnormal Twitter attention reportedly relates positively to contemporaneous and one-day-ahead returns, with predictive information concentrated in investor ticker-tweets rather than official crypto-channel posts. **Design consequence:** source class and timing matter; the contrast with *The Social Signal* is a reason to model platform, horizon, asset type and attention separately—not average the findings into a universal rule.
- **Sanhueza & Magner, “Born to Die: What Determines Early Collapse in the Cryptoasset Market?”** [SSRN 7226322](https://papers.ssrn.com/sol3/papers.cfm?abstract_id=7226322). The abstract describes 5,559 cryptoassets observed from 2014–2026, with a launch-time structural model and a stronger model after adding the first 30 days of price behaviour. It reports weaker generalisation for structural-only models on 2024–2025 cohorts. **Design consequence:** compare launch-time risk with dynamically updated risk, while preventing post-launch features from leaking into launch-time predictions. Audit its asset coverage and failure definition before using reported rates as a Solana prior.
- **Wen, Xu & Rong, “Which Assets Become Active, and What Persists? Market-Activity Lifecycles in China A-Shares and Pump.fun.”** [SSRN 7307252](https://papers.ssrn.com/sol3/papers.cfm?abstract_id=7307252). The abstract distinguishes entry into a high-activity state from persistence after entry; for its Pump.fun cohorts, prior deployer history reportedly added signal beyond creation-time controls, while narrative mappings did not add multiplicity-adjusted gain. **Design consequence:** model (A) entry into an activity state and (B) duration/decay after entry as separate targets. Verify cohort definition, historical availability of deployer features, and the paper's full protocol before promotion.
- **Tarantelli, Marino, Naviglio & Lillo, “Predicting the success of new crypto-tokens: The Pump.fun case.”** [SSRN 6543715](https://papers.ssrn.com/sol3/papers.cfm?abstract_id=6543715). The available SSRN record is a one-page posting and describes predicting graduation using bonding-curve SOL and structural/behavioural variables. **Design consequence:** it is a discovery lead, not implementation-grade evidence until full model specification, temporal split, sample construction, calibration and label verification are available.
- **Zhai, “The Prediction Paradox: Why Machine Learning Models Fail to Predict Cryptocurrency Prices in Live Trading.”** [SSRN 6566940](https://papers.ssrn.com/sol3/papers.cfm?abstract_id=6566940). The abstract contrasts a high walk-forward AUC with negligible reported live PnL and describes only five live trades for a more complex model. **Design consequence:** treat small live samples as anecdotal; evaluate calibration and economic utility with confidence intervals and adequate prospective sample size, not AUC alone.

#### Adversarial interpretation

1. **Do not vote-count papers.** Different universes, horizons, labels, fee assumptions and research flexibility can explain apparent disagreement. A newer or larger study is not automatically more valid.
2. **Keep two targets separate:** “Will the token reach a price/activity threshold?” and “Can the system enter and exit before adverse movement at realistic size?” Graduation is not equivalent to a tradable return; a price spike is not equivalent to a profitable exit.
3. **Measure lead time after data arrival.** Each feature needs event time, first-observed time and decision time. Evaluate alerts against the price available after expected network/provider/route latency, not the event's retrospectively reconstructed price.
4. **Control endogenous features.** Buyer count, volume, price change and social attention may be mechanically produced by the same coordinated wallets or by a launchpad's ranking mechanism. Use wallet-cluster-excluded outcomes, lagged features and ablations to test whether apparent lift is circular.
5. **Treat absence as a state, not a value.** A missing social feed, stale pool state, truncated funding history or unverified graduation label must be represented as missing/unknown and can trigger DATA_BLOCKED. Do not interpret unavailable evidence as “no risk.”
6. **Track selection across the whole pipeline.** Log every token seen, rejected, timed out, filtered as unsafe and never traded. Evaluate rejected-token counterfactuals with fixed horizons and matching on token age/liquidity; otherwise the system can appear safe by silently discarding inconvenient failures or appear successful by measuring only survivors.
7. **Use nested chronology.** Training, threshold selection, calibration and final evaluation must be separated in time; purge overlapping target horizons, cluster uncertainty by launch/day/cohort, freeze a final holdout, and disclose every tested configuration.
8. **Promotion gate:** no feature enters the live alert score because a paper reports significance. First reproduce its definition, then test incremental value against a simple baseline, then confirm calibration, net-executable lift and stability across chronological cohorts/providers. Manipulation and data-quality vetoes remain independent of the ranking score.

#### Revised priority order

1. Verify and improve collection coverage/freshness and record event, receipt and decision timestamps.
2. Audit labels and preserve the full point-in-time token universe, including failed and rejected launches.
3. Build interpretable baseline models for target-before-adverse-move, time-to-target and exit feasibility.
4. Run manipulation-aware ablations: exclude likely coordinated wallets from buyer-flow features; separate organic/official/social attention; compare fixed-window versus rolling metrics.
5. Use precommitted walk-forward evaluation, explicit latency and size-dependent execution costs, tail-risk reporting, and an untouched final holdout.
6. Only then consider more complex ML or online adaptation; complexity must earn its place through reproducible incremental utility.

**Research status:** these findings strengthen the validation design, not a profitability claim. No cited study by itself establishes a reliable, tradable early-momentum edge for Autopsy-X on Solana memecoins.


**Updated status:** this pass expands the research and test design only. No production collector changes were made, and no profitable early signal has yet been demonstrated on Autopsy-X's own point-in-time data. The key empirical question remains: *does any feature set produce earlier, calibrated, net-executable alerts than simple baselines on a sufficiently complete Solana memecoin universe?*
