# FLIPDEMON EXTREME: SSRN Evidence Review for Execution Safety

**Review date:** 2026-10-16  
**Scope:** execution realism, risk gates, backtest validity, and operational assurance for the MT5 FLIPDEMON EXTREME EA.  
**Status:** evidence-informed engineering review; not a profitability claim or deployment approval.

## Executive finding

The literature supports treating execution and validation as first-class parts of an automated trading system. It does **not** establish that this EA has alpha, that its stop/target rules are profitable, or that static source tests certify safe live execution. The practical response is to preserve fail-closed risk checks, reconcile broker-confirmed state, model costs and latency, and require tick-level/out-of-sample validation before any live mode.

## Evidence map

| Paper | Evidence described by the paper | Engineering implication | Transfer limitation |
|---|---|---|---|
| Bailey, Borwein, López de Prado, Sim & Wu, *Statistical Overfitting and Backtest Performance* (SSRN 2507040, 2014/2015) — https://ssrn.com/abstract=2507040 | Searching many parameter combinations can select an apparently optimal strategy that performs poorly out of sample. | Keep a record of all tested variants; use untouched validation/OOS periods and multiple-testing-aware metrics. Do not promote a parameter set because it wins an in-sample optimization. | General backtest-overfitting result, not an audit of this EA. |
| Wiecki, Campbell, Lent & Stauth, *All that Glitters Is Not Gold* (SSRN 2745220, 2016) — https://ssrn.com/abstract=2745220 | In a cohort of 888 strategies, conventional backtest metrics such as Sharpe ratio had little explanatory power for OOS performance in their sample; drawdown and other features added information. | Report OOS return, max drawdown, tail loss, turnover, exposure, and robustness—not Sharpe alone. | Quantopian strategy cohort; its exact estimates do not transfer automatically to MT5 FX/CFD execution. |
| Ito, Yamada, Takayasu & Takayasu, *Execution Risk and Arbitrage Opportunities in the Foreign Exchange Markets* (SSRN 3525947; NBER WP 26706, 2020, revised 2025) — https://ssrn.com/abstract=3525947 | Short-lived FX opportunities are not necessarily executable; the probability that all required orders fill affects expected profit. | A signal is not a fill. Measure request/acknowledgement latency, rejects, partial fills, slippage and realized P&L after costs. | Focuses on FX arbitrage and multi-leg execution, not this EA's single-symbol strategy. |
| Albers et al., *The Good, the Bad, and Latency: Exploratory Trading on Bybit and Binance* (SSRN 4677989, 2024) — https://ssrn.com/abstract=4677989 | A large live-order experiment reports discrepancies between expected and realized execution linked to latency, volatility and liquidity, including adverse selection for taker orders. | Capture expected quote versus actual fill, spread, slippage and latency by volatility/liquidity regime; test adverse execution during fast moves. | Crypto exchange order books differ from OTC FX/CFD broker execution. Treat mechanisms as hypotheses to test, not calibrated values. |
| Claeys, *When Backtests Guess: How Trading Platforms Silently Fabricate Results* (SSRN 6240638, 2026 preprint) — https://ssrn.com/abstract=6240638 | The preprint argues that OHLC bars cannot establish event ordering when stop-loss and take-profit both fall inside one bar; it reports material ambiguity for a specific NQ scalping setup. | For a fast scalper, use real ticks where available and document the tester's fill model. Add conservative handling for ambiguous stop/target sequences. | New preprint; the reported 18.47% is specific to its NQ data and setup and must not be copied as an FX estimate. |
| Lim, *Testing Common Forex Trading Strategies: A Null Result* (SSRN 6871118, June 2026 preprint) — https://ssrn.com/abstract=6871118 | Reports that several retail-accessible FX strategies did not survive its costs, multiple-testing and walk-forward protocol. | Require net-of-costs, walk-forward evidence and a simple baseline. A positive gross backtest is insufficient. | Recent single preprint; it is not a universal proof that all FX strategies fail. |
| Deng, *Preventing Silent Semantics Drift in Automated Trading Systems* (SSRN 6071832, 2026 preprint) — https://ssrn.com/abstract=6071832 | Proposes explicit pre-run semantic checks, runtime guards, fault injection, and an auditable decision trail. | Pin execution mode, risk parameters and cost assumptions; test kill switches and configuration faults; preserve reason-coded logs and test artifacts. | A preprint describing its own assurance layer; it is a design reference, not independent certification of this EA. |
| Cartea, Donnelly & Jaimungal, *Algorithmic Trading with Model Uncertainty* (SSRN 2310645; journal publication noted on SSRN) — https://ssrn.com/abstract=2310645 | Models uncertainty in market-order arrivals, limit-order fill probability and mid-price dynamics, linking uncertainty to inventory and adverse-selection risk. | Do not treat estimated spread, impact, or fill probability as known constants; stress test parameter uncertainty and fail closed when required inputs are unavailable. | Market-making model; not a direct position-sizing formula for this EA. |

SSRN hosts working papers, preprints, and papers later published elsewhere. The status differs by item; abstracts alone do not establish independent replication. Use each item as a source of testable engineering hypotheses, not as proof of trading performance.

## Required implementation and validation controls

1. **Account-wide vs symbol-specific exposure:** account-wide open-position and gross-lot caps must use account-wide totals. Symbol/directional caps must use symbol/directional totals. Never pass symbol exposure into an account-wide limit by mistake.
2. **Final-size risk check:** after every sizing multiplier, normalization, or affordability adjustment, recompute stop-loss risk in account currency using the broker's profit calculation and reject if it exceeds the configured budget or cannot be calculated.
3. **Execution reconciliation:** require server retcode checks plus broker-confirmed position/order state. Never blindly retry ambiguous timeout/connection outcomes; reconcile before another request.
4. **Partial-fill accounting:** journal actual closed volume and actual remaining exposure, not requested volume. Handle a full close masquerading as a partial close as a separate reconciliation event.
5. **Protective stops:** distinguish failure to improve a stop from absence of protection. Never assume a modify request succeeded; inspect the installed stop and record the decision.
6. **Execution stress tests:** inject timeout, connection loss, delayed acknowledgement, partial fill, rejection, stale quote, spread spike, foreign/manual position, missing stop, and restart/reconnect scenarios. Assert no duplicate exposure and no unowned-position mutation.
7. **Backtest integrity:** use real-tick testing for scalping where available; pin data, spread, commission, swaps, latency/slippage assumptions, and tester mode. Report ambiguous-bar handling and a pessimistic sensitivity case.
8. **Out-of-sample evidence:** pre-register the primary metrics and evaluation windows; keep a sealed OOS period; include net costs, drawdown, tail loss, trade count, regime splits and a benchmark. Record every experiment to expose selection bias.
9. **Release gate:** static tests passing is necessary but insufficient. Require a clean MetaEditor compile, reproducible Strategy Tester reports, and a demo forward-test reconciliation before considering live execution.

## Current code-review finding

The merge-conflict investigation found newer account-wide exposure checks in the base branch while the safety patch added a combined position counter. The combined counter's symbolExposureLots is symbol-specific; it must **not** be supplied as the account-wide gross-lot input to PreTradeAllowed. The merged fix keeps separate account-wide totals for account caps and symbol-specific totals for projected symbol/directional exposure. A regression assertion is added for this distinction.

## Release status

- A separate path-fix PR was retargeted to the execution-safety branch and GitHub reported it clean.
- This rebased safety candidate includes a reconciliation of the account-wide exposure gate and final-volume checks; fresh CI is required.
- No verified MetaEditor compile, MT5 Strategy Tester report, or demo forward-test evidence is asserted by this document.
