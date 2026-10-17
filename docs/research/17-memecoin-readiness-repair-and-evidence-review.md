# Memecoin Momentum: Evidence-to-Code Review and Data-Readiness Repair

Status: research and engineering change proposal, 2026-10-17. No profitability or live-trading claim.

## Executive decision

Do not train or score a tradable model until the acquisition pipeline has measured point-in-time liquidity coverage and the data-readiness gate passes. The immediate engineering defect addressed in this branch is that the acquisition duration clock was started before universe discovery and historical backfill. Setup work could consume most of the observation budget, leaving too few live polls to establish 5m/15m/60m coverage. The clock now starts after discovery, backfill, and initial enrichment, and run.json records the observation start, duration, cycle count, and elapsed time.

This repairs the timing defect in the current default-branch implementation. It does not manufacture missing historical liquidity observations, prove a fresh acquisition passed, or make the strategy ready to trade. A new acquisition and independent readiness audit are still required.

## Research findings and engineering implications

### 1. Memecoin activity can be manufactured

- Mongardini and Mei, A Midsummer Meme's Dream: Investigating Market Manipulations in the Meme Coin Ecosystem (2025), analyze 34,988 tokens across Ethereum, BNB Chain, Solana, and Base. They report widespread evidence of wash trading and liquidity-pool-based price inflation among high-return tokens. [arXiv paper](https://arxiv.org/abs/2507.01963) and [Zenodo record](https://zenodo.org/doi/10.5281/zenodo.15388345).
- Ding et al., Decompose Market Manipulation Strategies: Evidence from On-chain Meme Coin Market (SSRN, 2025), analyze 6,000 Pump.fun tokens and distinguish concealed accumulation/sniping, wash trading, and fabricated comments. [SSRN 5953738](https://ssrn.com/abstract=5953738), [UCL Discovery copy](https://discovery.ucl.ac.uk/id/eprint/10220651/).
- Szwajcok et al., Meme Coin Factories: Uncovering Large-Scale Manipulations on pump.fun (arXiv, 2026), report large-scale patterns including wash trading, creator-address obfuscation, coordinated selling, copycats, and social manipulation. This is a recent preprint, so treat its claims as provisional pending independent replication. [arXiv 2609.10246](https://arxiv.org/abs/2609.10246).

Implementation: volume and unique-wallet counts are not standalone proof of demand. Add cross-feature manipulation flags: repeated/self-funded wallets, suspiciously synchronized buys, creator/early-holder concentration, abnormal turnover relative to liquidity, buyer breadth, rapid liquidity withdrawal, and social duplication. Treat these as risk flags with evidence and confidence, not automatic claims of fraud.

### 2. Momentum evidence is conditional, not a free edge

- Fracassi and Kogan, Pure Momentum in Cryptocurrency Markets (2022), show that reported 24-hour return displays can induce responses to changes unrelated to new information. [SSRN 4138685](https://ssrn.com/abstract=4138685).
- Han, Kang, and Ryu, Momentum in the Cryptocurrency Market: A Comprehensive Analysis under Realistic Assumptions (accepted at Review of Asset Pricing Studies; SSRN version revised 2026), report strong time-series momentum evidence but weak cross-sectional momentum, with liquidation and heavy-tailed outcomes materially affecting results. [SSRN 4675565](https://ssrn.com/abstract=4675565).
- Grobys and Shahzad, Cryptocurrency momentum: Is it an illusion? (2023), emphasize power-law variance and the danger of relying on conventional Sharpe/t-statistic interpretations under extreme tails. [SSRN 4633099](https://ssrn.com/abstract=4633099).

Implementation: separate short-horizon acceleration from rolling 24-hour return; calculate momentum only from data observed by decision time. Compare price-only, price/volume, liquidity-only, on-chain, and combined models. Report tail loss, drawdown, worst-decile outcomes, and trade-level cost sensitivity, not only mean return or Sharpe ratio.

### 3. Liquidity must be measured as executable capacity

- Brauneis et al., How to measure the liquidity of cryptocurrency markets? (Journal of Banking & Finance, 2021), compare high-frequency liquidity benchmarks with lower-frequency estimators. They find no universally best measure; Amihud illiquidity and Kyle/Obizhaeva-style estimators help estimate liquidity levels, while spread estimators can capture variation. [Journal article](https://www.sciencedirect.com/science/article/pii/S0378426620303022).

These results concern major cryptocurrencies and conventional venues, not direct validation of Solana AMM microstructure. Use them as measurement guidance, not proof that a metric transfers unchanged to newly launched pools.

Implementation: keep observed pool liquidity, estimated slippage/price impact, swap size, fees, priority fees, and failure/latency costs separate. A token is not tradable merely because displayed pool liquidity is nonzero. Estimate buy and sell impact at the intended notional, and reject stale or missing snapshots.

### 4. Small paper-trading samples are especially fragile

- Kamat, Hour-Aware Adaptive Risk Management for Autonomous Memecoin Trading on Solana DEXs (SSRN, October 2026), reports a 190-trade, 15-day paper-trading sample. The author states that removing the top three trades flips the cumulative result unprofitable, and the hour-of-day finding is exploratory and statistically non-confirmatory. This is a self-authored working paper, not independent proof of profitability. [SSRN 6564803](https://ssrn.com/abstract=6564803).
- Bailey and López de Prado, The Deflated Sharpe Ratio (2014), addresses selection bias, non-normal returns, and backtest overfitting. [Journal of Portfolio Management reference](https://doi.org/10.3905/jpm.2014.40.5.094).
- Harvey, Liu, and Zhu, ...and the Cross-Section of Expected Returns (2016), discusses multiple testing and the need for more demanding evidence thresholds when many hypotheses are searched. [NBER working paper](https://www.nber.org/papers/w20592).

Implementation: freeze hypotheses before the final holdout; correct for multiple testing; use chronological walk-forward splits; preserve rejected-token outcomes; evaluate counterfactuals for rejected signals; and publish ablations and sensitivity tests. Do not use the same period to tune thresholds and claim final performance.

## Data-readiness contract

A run is READY_FOR_RESEARCH only when all checks pass:

1. Acquisition provenance and dataset hashes verify.
2. Poll-window telemetry shows the requested observation duration was actually allocated to live polling.
3. Per-pool timestamps are monotonic and point-in-time safe. Event time, first-seen time, feature-ready time, and decision time are distinct.
4. No future or late-ingested snapshot is backdated into a decision feature.
5. Required contiguous 5m, 15m, and 60m liquidity coverage passes the frozen contract for each eligible pool.
6. Missing, stale, unmatched, failed, and identity-mismatched observations have explicit, mutually exclusive reason codes.
7. No historical OHLCV bar is relabelled as having historical liquidity unless a contemporaneous liquidity observation exists.
8. Every discovered pool remains represented, including failures, dead pools, rugs, and excluded pools, with a reason code.
9. The run report states eligible pool count, pool-level pass count, usable-bar share, gaps, provider errors, and observation cadence.
10. Readiness failure blocks model training and performance claims. Thresholds may only change through a versioned, justified protocol amendment, never merely to turn a failing run green.

## Validation sequence

1. Run unit and architecture regression tests.
2. Run the acquisition workflow using the repaired timer.
3. Verify the archived run.json, provenance report, raw manifest, and canonical hashes.
4. Run the existing Phase 3D point-in-time liquidity audit on the new archive.
5. Compare requested vs measured duration, cycle cadence, provider errors, and per-pool coverage.
6. If readiness fails, fix the diagnosed cause or improve provider/source coverage. Do not synthesize liquidity history or loosen freshness limits.
7. Only after readiness passes, run baseline and feature-ablation evaluation with frozen out-of-sample windows and realistic execution costs.

## Scope boundary

This is a standalone memecoin research system. It does not connect to AUTOPSY X, XAUUSD, MT4/MT5, or the forex EA. Acquisition code is read-only and does not submit trades. A green unit/CI run proves software checks, not data sufficiency, predictive power, execution quality, or profitability.