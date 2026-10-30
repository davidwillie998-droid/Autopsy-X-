# FlipDemon Extreme HFT: Account and Campaign Coordination

Status: **PARTIAL IMPLEMENTATION / NOT APPROVED FOR PYRAMIDING OR MULTI-SYMBOL EXECUTION**

Execution mode remains `AX_EXEC_ANALYSIS_ONLY`. This change does not authorize live orders.

## Implemented in this branch

### Broker-backed account stop-risk admission

`MQL5/Include/AutopsyX/AccountCampaignCoordinator.mqh` adds a fail-closed coordinator that:

- Enumerates every open account position, across symbols and magic numbers.
- Requires a valid protective stop on every open position before permitting additional risk.
- Calculates each position's monetary stop risk with `OrderCalcProfit`, using its own symbol, direction, entry, stop and volume.
- Aggregates account-wide open stop risk and same-symbol/same-magic campaign stop risk.
- Checks the proposed order after the EA's existing risk, AFE and impact-cost sizing stages.
- Enforces a hard 2.00% absolute per-entry ceiling, a default 2.00% same-symbol campaign ceiling and a default 4.00% account-wide open-risk ceiling.
- Blocks new risk when equity, a position stop, or a broker profit calculation cannot be verified.

The EA calls this gate before the final broker-margin preflight and before `CExecutionEngine::OpenMarket`. Existing position management remains outside this admission gate.

## Not implemented yet

These requirements remain explicit blockers. Do not mark them complete based on the reference tests or this coordinator.

1. **Strongest-opportunity multi-symbol scanner:** the current live signal engines, market-data object, risk sizing call and position manager are still chart-symbol scoped. A candidate-ranking helper alone would not make cross-symbol execution safe. The scanner must own independent per-symbol market state and pass the selected symbol through sizing, stops, execution, recovery, management and journaling.
2. **Campaign ledger and 10-entry pyramiding:** the current EA still manages one tracked position state and has no durable per-entry campaign ledger with unique continuation-signal IDs. The ten-entry ceiling is not enabled. Adds remain disabled until entry-deal attribution, persistence, restart recovery and partial-close accounting work for both account modes.
3. **Equity-responsive progressive sizing:** ordinary risk-percent sizing already changes monetary size with equity, but the additional growth-tier multiplier is not wired into execution. It must be applied only after realized-equity validation and fresh continuation confirmation, then pass all existing AFE, per-entry, campaign and account caps.
4. **Hedging-account execution reconciliation:** the current EA has an explicit initialization rejection for retail-hedging accounts. The new account-risk snapshot can enumerate multiple broker positions, but this does not make the rest of the EA hedging-safe. Do not remove the rejection until per-ticket execution, partial close, stop modification, campaign attribution and restart recovery are implemented and tested.
5. **Netting campaign-leg attribution:** a netting broker exposes one aggregate position per symbol. Reconstructing up to ten campaign entries requires durable deal-level attribution and reconciliation of entry, reduction, reversal, partial-close and external/manual transactions. If attribution is uncertain, additions must remain blocked.

## Required next implementation sequence

1. Refactor the live engines into per-symbol contexts and add deterministic strongest-candidate selection.
2. Add a durable campaign ledger keyed by campaign ID, signal ID, symbol, magic and broker position identifier.
3. Implement broker-mode-specific reconciliation: one aggregate position plus deal ledger on netting; individual position tickets plus deal ledger on hedging.
4. Implement continuation-only adds, maximum ten entries, no reused signal IDs, no losing-campaign adds, and verified protective stops on every leg.
5. Add realized-equity progression tiers and persist the sizing baseline/high-water mark.
6. Add Strategy Tester cases for netting and hedging, including restart, partial fill, partial close, reversal, stop modification, missing history and external position changes.
7. Compile the complete EA in MetaEditor and run deterministic Strategy Tester and demo-forward tests.

## Verification boundary

The new Python tests are reference/accounting tests plus source-contract checks. They do not execute the MQL5 coordinator. The static safety workflow is extended to inspect the new source contract. MetaEditor compilation and MT5 runtime verification remain unavailable until run on an MT5-capable Windows host.

No profitability, HFT latency, broker compatibility or live-readiness claim is made.
