# FLIPDEMON EXTREME: Evidence Expansion for Adaptive Pyramiding

**Status:** Research synthesis for design and validation. Not a live-trading authorization, not a performance claim, and not yet integrated into the MQL5 execution path.

**Scope:** MT5 execution safety, trend-following/pyramiding logic, volatility-aware sizing, liquidity and slippage, and statistical validation. This is a literature-informed engineering specification, not proof that pyramiding will be profitable on a particular broker or symbol.

## Executive finding

The strongest defensible design is **add to a validated winning campaign only when new information confirms continuation, while keeping the original campaign risk budget fixed**. The evidence base supports trend/momentum as a possible source of returns in some markets and supports careful volatility/risk scaling, but it does not establish a universally optimal pyramid schedule, a guaranteed edge from adding positions, or any fixed multiplier such as 1.5x. The pyramid matrix must be evaluated net of realistic execution costs and on untouched forward data.

## Evidence register

| Source | Main result relevant to design | Evidence class and limitation |
|---|---|---|
| Thomas, Clare, Seaton & Smith, *Trend Following, Risk Parity and Momentum in Commodity Futures* (SSRN 2126813, 2012) | Combining trend-following and momentum improved reported risk-adjusted outcomes versus simple momentum in their commodity-futures study; trend-following contributed more than risk-parity adjustments in their tests. | SSRN working paper; commodity futures are not identical to leveraged retail FX/CFDs, and results do not validate this EA. https://papers.ssrn.com/sol3/papers.cfm?abstract_id=2126813 |
| Baltas & Kosowski, *Momentum Strategies in Futures Markets and Trend-following Funds* (SSRN 1968996) | Studies links between time-series momentum benchmarks and CTA returns, including capacity constraints. | SSRN research; supports studying trend exposure, not a specific entry ladder or lot multiplier. https://papers.ssrn.com/sol3/papers.cfm?abstract_id=1968996 |
| Molyboga, Swedroe & Qian, *Short-Term Trend: A Jewel Hidden in Daily Returns* (SSRN 3542364, 2020) | Reports time-series momentum results across 78 futures markets and says volatility-based sizing and implementation checks mattered. | Broad futures sample, daily horizons; cannot be assumed to transfer directly to intraday MT5 execution. https://papers.ssrn.com/sol3/papers.cfm?abstract_id=3542364 |
| Bailey, Borwein, López de Prado & Zhu, *The Probability of Backtest Overfitting* (SSRN 2326253; Journal of Computational Finance) | Proposes combinatorially symmetric cross-validation to estimate how often the selected backtest configuration is overfit. | Methodological foundation; must be adapted carefully to time-dependent financial data. https://papers.ssrn.com/sol3/papers.cfm?abstract_id=2326253 |
| Bailey et al., *Pseudo-Mathematics and Financial Charlatanism* (SSRN 2308659) | Shows how searching many configurations can produce apparently strong but spurious backtests. | Strong warning against tuning the pyramid matrix to a small set of spectacular runs. https://papers.ssrn.com/sol3/papers.cfm?abstract_id=2308659 |
| Butt & Virk, *Momentum Crashes and Variations to Market Liquidity* (SSRN 3314095, 2019) | Finds liquidity variation is associated with momentum-crash risk in their sample. | Supports a liquidity-state risk overlay; not a calibrated threshold for this EA. https://papers.ssrn.com/sol3/papers.cfm?abstract_id=3314095 |
| Adams, Chan, Markovich & Wan, *Don't Let MEV Slip: The Costs of Swapping on the Uniswap Protocol* (arXiv 2309.13648; 2023/2024) | Finds execution costs depend on trade characteristics; for larger swaps, price impact and slippage dominate more often, and PEPE showed higher adversarial-slippage probability than a mature asset in their sample. | DEX study, not MT5 broker execution, but illustrates why nominal price and candle backtests can misstate realizable results. https://arxiv.org/abs/2309.13648 |
| Li, Shin & Wang, *Cryptocurrency Pump-and-Dump Schemes* (JFQA, online 2025) | Documents short episodes with sharp price/volume/volatility increases followed by rapid reversals, with evidence consistent with wealth transfer from outsiders to insiders. | Crypto-specific caution; not a direct FX/Gold model, but relevant to avoiding late-stage chasing. https://www.cambridge.org/core/journals/journal-of-financial-and-quantitative-analysis/article/abs/cryptocurrency-pumpanddump-schemes/97149DCD519BAF838F269F98DC76D682 |

## Engineering implications

### 1. Treat the pyramid as one campaign, not a stack of independent trades

- Define a campaign with a unique ID, direction, initial thesis, initial stop/invalidation level, and a **fixed maximum loss budget**.
- Calculate risk across all open entries against the campaign's actual shared invalidation/exit logic, including commission, spread, swap where applicable, and a slippage reserve.
- Never increase the campaign risk budget because floating profit or account equity has risen. Do not let repeated entries silently compound the original risk allowance.
- If the platform cannot reliably reconcile live positions, pending orders, fills, partial fills, and stops after restart/reconnect, block new add-ons.

### 2. Require new evidence before every add-on

A favorable floating P/L alone is insufficient. An add-on should require all of:
- the original thesis remains valid and the market regime remains compatible;
- a fresh, timestamped continuation signal has occurred since the prior add-on;
- the market has not exceeded a defined extension/chase threshold;
- spread, volatility, execution quality, margin headroom, and account/symbol/directional exposure pass hard limits;
- the expected incremental reward after costs is sufficient for the incremental risk.

No averaging down, no adding to a losing campaign, and no adding merely to recover a loss. When any required input is missing or stale, fail closed.

### 3. Size from risk, then normalize to broker constraints

Do not treat a target-lot ladder as a final order size. For each candidate entry:
1. Estimate loss at the applicable stop using the symbol's tick size/value and account currency.
2. Reserve costs and a stress slippage allowance.
3. Compute remaining campaign risk budget after existing and pending exposure.
4. Compute the maximum permissible volume from that remaining budget.
5. Apply broker min/max/step normalization **downward**, then recalculate risk on the normalized volume.
6. Reject the add-on if the normalized minimum volume would breach risk, margin, or exposure caps.

A 1.5x stage multiplier is only a parameter to test, not an evidence-backed default. Compare equal, modestly increasing, and risk-adaptive schedules under the same fixed campaign-risk ceiling.

### 4. Volatility and liquidity are separate controls

- Volatility sizing controls the risk implied by price movement; it does not guarantee liquidity.
- Spread and margin checks do not fully capture market impact or slippage.
- For fast markets, widen the execution-cost reserve or prohibit new adds; do not compensate for worse conditions by increasing lots.
- Distinguish broker-reported spread from realized execution slippage. Record requested price, fill price, latency, rejection/retcode, and market state for every attempt.

### 5. Backtest design must resist selection bias

Before selecting a schedule:
- freeze the candidate rules and record every configuration tried;
- use chronological train/validation/test partitions and walk-forward evaluation;
- keep a final untouched out-of-sample period;
- use purging/embargo where labels or trades overlap in time;
- include spread, commission, swap, realistic slippage, rejected orders, latency assumptions, and stop-gap stress;
- report performance by symbol, session, volatility regime, spread regime, direction, and campaign stage;
- report expectancy, profit factor, max drawdown, tail loss, exposure, turnover, average adverse/favorable excursion, and performance net of costs;
- use a multiple-testing correction or PBO-style analysis when many variants are compared;
- compare against a no-pyramiding baseline and a single-entry baseline. If pyramiding does not improve net risk-adjusted results out of sample, keep it disabled.

Do not use a high-return screenshot or the best historical path as validation. Survivorship, hindsight, cherry-picked windows, and unmodeled fills can make extreme outcomes look more repeatable than they are.

## Proposed test matrix

| Dimension | Candidate tests | Required interpretation |
|---|---|---|
| Stage count | 1, 2, 3, 5, 8, 15 as a hard ceiling test | More stages must not automatically mean more orders; test whether incremental stages add net value. |
| Schedule | Equal; conservative increasing; risk-adaptive | Keep campaign risk and entry eligibility constant across variants. |
| Confirmation | Fresh structure break/pullback continuation; no fresh confirmation | Negative-control variant should show why the gate matters; do not promote it as a candidate. |
| Regime | Trend, range, transition, shock/high-volatility | Measure regime-specific expectancy and tail loss. |
| Execution | Baseline costs; doubled spread/slippage; delayed fill; rejection; gap through stop | Determine whether the edge survives plausible execution deterioration. |
| Risk budget | Multiple predeclared low-risk test budgets | Never choose the budget solely because it maximizes historical return. |
| Validation | Walk-forward, untouched holdout, bootstrap/campaign resampling, PBO-style selection check | Report uncertainty, not only point estimates. |

## Promotion gates before MQL5 integration

1. **Research gate:** hypotheses, thresholds, and configuration search space documented before testing.
2. **Data gate:** enough complete tick/bar and execution-quality data across relevant market regimes; missing intervals are explicitly reported.
3. **Reference-model gate:** deterministic unit tests for hard gates, volume rounding, campaign risk, restarts, partial fills, and stale inputs.
4. **MQL5 source gate:** code review confirms all add-on paths reuse hard safety checks and cannot bypass existing daily/weekly/loss-streak locks.
5. **MetaEditor gate:** compile cleanly on the intended MT5 build with no errors; warnings reviewed.
6. **Strategy Tester gate:** realistic tick model and costs, no look-ahead, no accidental parameter leakage, and reproducible reports.
7. **Demo-forward gate:** reconcile every signal, request, fill, stop, partial close, reconnect, and restart against broker state.
8. **Release gate:** keep analysis/paper mode default; live mode remains disabled until explicit review and all gates pass.

## Important limitation

This evidence is not a claim that pyramiding will make the EA profitable. The cited work covers different markets, time horizons, venues, and methods. It provides design constraints and test hypotheses. Any numeric thresholds, stage multipliers, and risk limits must be calibrated to the actual symbol, broker contract, account currency, execution conditions, and verified out-of-sample results.

## Additional references

- *The Probability of Backtest Overfitting*, open academic copy: https://escholarship.org/uc/item/4w1110bb
- *Cryptocurrency Pump-and-Dump Schemes*, Journal of Financial and Quantitative Analysis: https://doi.org/10.1017/S0022109025000201
- *The Microstructure of the 'Flash Crash': Flow Toxicity, Liquidity Crashes and the Probability of Informed Trading*: https://papers.ssrn.com/sol3/papers.cfm?abstract_id=1695041
