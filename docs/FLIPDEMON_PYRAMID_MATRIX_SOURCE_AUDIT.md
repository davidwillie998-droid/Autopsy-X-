# FLIPDEMON EXTREME Adaptive Pyramid Matrix: Source Audit

**Status:** Research implementation and reference tests only. This document and the Python reference model do not authorize MQL5 order execution or change live settings.

## Source-trace findings

Reviewed against the fix/flipdemon-extreme-safety-rebased-20261016 candidate:

| Area | Current source behaviour | Consequence for pyramiding |
|---|---|---|
| EA defaults | InpMaxOpenPositions=1, InpMaxPositionsPerSymbol=1 | A multi-entry campaign is currently blocked by configuration. |
| Exposure defaults | InpMaxExposureLots=1.0, InpMaxDirectionalExposureLots=1.0 | Raising only the position count cannot permit larger aggregate exposure. |
| Risk sizing | CRiskEngine::CalculateLotSize uses equity times configured risk percent, stop distance, tick size/value, and a gross-lot cap; volume is normalized after the cap. | A pyramid needs campaign-level risk accounting, not repeated independent per-entry sizing. |
| Risk gates | PreTradeAllowed checks daily/weekly locks, loss streak, execution failures, account/symbol position counts, gross and directional lots, spread, margin usage and margin level/free margin. | The add-on decision must reuse or strictly preserve every hard gate, with projected values for the proposed order. |
| Final preflight | The EA recalculates stop risk using OrderCalcProfit, checks projected margin with OrderCalcMargin, and checks exposure after adaptive/impact sizing and volume normalization. | The same ordering must be maintained for every add-on, including a second check after final volume normalization. |
| Execution | CExecutionEngine::OpenMarket refuses an existing position on the symbol and requires confirmed server fill plus broker-position confirmation. Ambiguous timeout/connection outcomes are not blindly retried. | Pyramiding requires a deliberate campaign-aware execution and reconciliation design. Removing the existing-position guard alone would be unsafe. |
| Position state | The main EA currently tracks a single g_posState / g_haveOpenPosition record for its active trade. | Multi-ticket or staged netting adds require a campaign ledger, ownership rules, restart recovery, and aggregate exit handling. |
| Account mode | Static safety checks require unsupported hedging accounts to fail initialization. | Netting/hedging semantics must be defined and tested explicitly before enabling multi-position mode. |

## Reference-model contract

research/flipdemon_pyramid_matrix.py is a pure Python decision oracle. It receives already-calculated account-currency risk and broker-aware margin inputs, then computes the maximum safe add-on volume. It does not connect to MT5, fetch quotes, place orders, or claim to predict profitability.

The model requires all of the following before it considers an addition:

- a fresh continuation confirmation and still-valid thesis;
- a validated market regime, acceptable spread/execution conditions, and required inputs available;
- reconciled broker position state;
- a currently winning campaign, so this policy never averages down;
- remaining campaign risk budget, account/symbol/directional lot headroom, margin headroom, and a valid position-count ceiling.

Volume is floored to the broker's volume step. If the safe result is below minimum volume, the decision is to reject. Projected campaign risk, exposure, free margin and margin usage are checked again after normalization. Invalid, non-finite, missing or inconsistent inputs fail closed.

**Important boundary:** the Python model is not a substitute for MQL5's broker-aware OrderCalcProfit / OrderCalcMargin calculations, actual installed-stop confirmation, fill reconciliation, or live position accounting. The risk-per-lot and margin-per-lot values supplied to the model must be conservative and independently validated by the eventual MQL5 integration.

## Required MQL5 integration before any cap change

1. Add an explicit, default-off pyramiding feature flag. Existing single-position behaviour remains the default.
2. Define a campaign identifier and track all campaign positions/deals, including partial closes, manual/foreign positions, and restart/reconnect recovery.
3. Define one campaign risk budget anchored to a documented equity reference at campaign start. Do not allow unrealised profit to silently increase that budget during the same campaign.
4. Reconcile netting and hedging account semantics, magic/comment ownership, aggregate stops, and the deterministic campaign exit policy.
5. Recalculate aggregate stop risk, projected margin, symbol/directional/account gross exposure, and all existing hard limits immediately before submission and after final volume normalization.
6. After fill, verify actual filled volume, actual broker position state, and installed SL/TP before permitting the next add-on. Ambiguous acknowledgement must block further additions until reconciled.
7. Test partial fills, rejected orders, timeouts, stop modification failures, terminal restart, gaps, slippage, spread shocks, and adverse reversal scenarios.
8. Keep the existing one-position/1.0-lot caps and analysis-only execution defaults unchanged until MetaEditor compilation, Strategy Tester, demo forward validation, and explicit review pass.

## Research stages

The 1, 3, 5, 8, 12 and 15 position stages are experimental ceilings, not a target to fill. Compare the single-entry baseline with equal-size, increasing-target-size and risk-adaptive add-ons under the same aggregate campaign risk budget. A requested larger tranche must be reduced or rejected if risk, exposure or margin capacity does not support it.

No claim of profitability is made. Promotion requires chronological out-of-sample evidence net of realistic spread, commission, swaps, slippage and execution failures, uncertainty reporting, robustness checks, and no unacceptable deterioration in drawdown or tail risk.
