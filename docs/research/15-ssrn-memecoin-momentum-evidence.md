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
