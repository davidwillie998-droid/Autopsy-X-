# FlipDemon Extreme: Conditional Pyramiding and Campaign Reversal Specification

Status: design contract with user-approved preferences; implementation and validation are still required.

## User-approved strategy preferences

- Add rule: permit an add after each fresh qualifying continuation setup, only when every existing entry gate and the campaign/account risk gates pass.
- Maximum campaign size: 10 entries total (one initial entry plus at most nine adds), not ten additional adds.
- Execution mode remains `AX_EXEC_ANALYSIS_ONLY` by default. Conditional pyramiding remains disabled until implementation, netting/hedging validation, aggregate-risk integration, and required tests pass.
- These preferences do not authorize live trading or relax any risk limit.

## Objective

Add conditional pyramiding and campaign-level directional flips to FlipDemon Extreme without weakening existing entry, execution, emergency-stop, drawdown, loss-limit, session, spread, slippage, Kelly, Adaptive Flip Engine, VWAP, H4/Daily, or broker-validity checks.

The strategy is for XAUUSD and GBPJPY only unless the user explicitly approves another symbol. Do not infer that a screenshot or another broker's position stack proves profitability.

## Non-negotiable safety invariants

1. `InpExecutionMode` remains `AX_EXEC_ANALYSIS_ONLY` by default. This work must never switch execution to LIVE.
2. No martingale, loss recovery sizing, averaging down, or unbounded position stacking.
3. A failed, unavailable, stale, contradictory, or unverified risk calculation rejects the add.
4. Every entry and add requires a valid protective stop-loss on the loss side of the entry. Do not assume a stop guarantees its exact fill during gaps or slippage.
5. Risk is measured at campaign and account level, not just per order. Include open positions, pending orders, other EA-managed campaigns, estimated commissions and conservative slippage where data are available. If any relevant exposure cannot be reconstructed, reject new adds.
6. Existing emergency stops and all current entry gates remain authoritative. Pyramiding is an additional gate, never a bypass.
7. Do not describe backtest, static-analysis, or source-review results as live readiness.

## Campaign lifecycle

Model a campaign explicitly with a stable campaign ID, symbol, direction, start time, entry count, last qualifying signal/bar, realized P&L, open volume, risk-at-stops, and lifecycle state.

States:
- `FLAT`: no EA-owned campaign.
- `INITIAL_ENTRY_PENDING`: initial order sent; reconcile broker state before proceeding.
- `ACTIVE`: confirmed campaign with a valid stop and reconciled exposure.
- `ADD_PENDING`: one add request outstanding; do not issue a duplicate.
- `EXITING`: close requested; reconcile partial fills and remaining exposure.
- `REVERSAL_PENDING`: old campaign must be confirmed closed and account/symbol exposure reconciled before a fresh opposite entry.
- `BLOCKED`: ownership, history, order result, risk, or position state is ambiguous; no new exposure until reconciliation succeeds.

Persist or reconstruct enough state after terminal restart to avoid duplicate adds. If the state cannot be reconstructed safely, manage existing exposure but block new entries until reconciled.

## Initial entry requirements

The existing signal and execution pipeline must approve the candidate. Reuse the existing direction, stop calculation, lot sizing, broker-volume validation, spread/slippage, session, H4/Daily regime, drawdown, loss limits, Kelly/AFE and emergency gates. A campaign record is created only after broker execution and actual filled volume/price are confirmed.

## Equity-responsive position sizing

Equity-responsive sizing is part of the approved conditional-pyramiding design. It must not become a fixed lot-escalation ladder.

- Recalculate the candidate order's permissible volume for every initial entry and every add using current account equity, the configured risk fraction, the valid stop-loss distance, broker tick/contract metadata, and estimated trading costs where available.
- As account equity increases, the monetary risk budget may increase proportionally under the configured risk policy. This permits larger lots only when the new stop distance, volume step, campaign aggregate stop-risk, account aggregate stop-risk, margin ceiling, and all other gates independently allow them.
- If equity falls or drawdown guards change state, the permitted risk budget must fall or new exposure must be blocked according to the existing Risk Engine and Adaptive Flip Engine policy. Never increase size to recover a loss.
- Do not use campaign entry number, winning streak, floating profit alone, or a predetermined multiplier ladder as a reason to increase volume. Every add must have a fresh qualifying continuation setup and its own valid stop-based risk calculation.
- Distinguish account balance, current equity, floating P&L, and peak equity. A temporary unrealized gain must not silently reset drawdown state or grant an unrestricted permanent risk increase.
- Compute the proposed order's risk together with all existing EA-owned exposure and pending orders. Existing positions consume the shared risk budget; never grant each pyramid entry a separate full account risk allowance.
- If the risk estimate, stop, quote, account equity, contract metadata, existing exposure, or projected margin cannot be verified, reject the new exposure. Do not silently widen stops or round volume upward beyond the approved risk budget.
- Round candidate volume down to the broker's valid volume step and reject the order if the resulting volume is below the broker minimum or otherwise invalid. A broker minimum must never force risk above the approved budget.

This rule authorizes a sizing design, not a promise of profits or a change to the EA's execution mode. `AX_EXEC_ANALYSIS_ONLY` remains the default, and pyramiding remains disabled until the implementation and validation gates pass.

## Add-to-winner requirements

An add is permitted only when all conditions pass:

- The campaign is active, EA-owned, directionally consistent, and has no unresolved order/close state.
- Current campaign P&L is positive after estimated trading costs; never add to a losing campaign.
- A fresh continuation setup is confirmed. Add after each fresh qualifying continuation setup, provided every gate passes. Require a new qualifying structure/displacement event and pullback/resumption confirmation; VWAP is supporting evidence, not a standalone trigger.
- The signal is new, not a duplicate tick or repeated processing of the same bar/event. Enforce a configurable minimum spacing/cooldown.
- Spread, slippage estimate, quote freshness, symbol trading status, session, and market regime remain acceptable.
- All existing gates pass for this add independently.
- Recalculate proposed total stop-loss risk and projected margin for the entire account/campaign after the add. Include existing positions and pending orders; use broker-aware calculations and reject if the result is unavailable or exceeds any configured hard cap.
- Enforce a hard maximum of 10 entries total per campaign (one initial entry plus at most nine adds) and maximum total account exposure. No unlimited-exposure mode. Reject any add after the tenth total entry.
- If the broker uses netting, track each deal/add in campaign history even though the broker aggregates the symbol into one position. If hedging, reconcile every EA-owned ticket and do not take ownership of manual or other-EA positions.
- Reconcile actual fills and volume after execution; partial fills update the campaign with actual volume. Ambiguous timeouts/connection failures must not trigger blind retries or duplicate adds.

## Stop adding / campaign protection

Immediately stop adding when any of these occur: campaign no longer profitable after costs; continuation invalidation; opposite setup reaches reversal criteria; drawdown/loss guard changes state; spread, slippage or impact exceeds limits; margin or aggregate risk reaches a cap; quote/data are stale; ownership or order state is ambiguous; emergency stop activates.

Do not silently widen stops to make an add fit. A stop modification must be separately validated and confirmed. Existing positions remain subject to the existing exit and emergency management logic.

## Directional reversal

A reversal is a new campaign, not an add:
1. Confirm the opposite setup using the existing flip engine plus the required structural confirmation.
2. Stop all adds to the old campaign.
3. Close the old campaign using confirmed close/reconciliation logic.
4. If any old exposure remains, a close is partial/ambiguous, or unrelated/manual exposure conflicts with policy, do not open the reverse campaign.
5. Re-run the complete fresh-entry pipeline for the opposite direction, including fresh stop, lot size and risk calculation.
6. Register the new campaign only after actual fill confirmation.

Never assume three confirming ticks are equivalent to three independently confirmed bars. Add stronger event/bar deduplication for campaign transitions.

## Account and broker compatibility

Before enabling multiple entries, detect and explicitly support both MT5 netting and hedging modes. Verify symbol volume minimum/maximum/step, tick size/value, contract size, stop/freeze levels, margin calculation, filling policy and execution mode. A broker-specific incompatibility must fail closed.

The current `CExecutionEngine::OpenMarket` rejects an existing position on the symbol, and the main EA's current position limit is one. These paths must be deliberately redesigned and tested; simply raising the position limit is insufficient. The current `CPortfolioRiskGate` is standalone and must not be treated as active protection until integrated and independently tested.

## Configuration contract

Add explicit inputs for:
- enable conditional pyramiding (default false until implementation and test gates pass);
- maximum entries per campaign, defaulting to the approved cap of 10 total entries (initial entry included);
- minimum time/bar spacing between adds;
- maximum aggregate campaign stop-risk;
- maximum account-wide aggregate stop-risk;
- maximum margin usage and total exposure;
- required continuation confirmations.

Validate every input at initialization. Reject impossible or contradictory settings. Do not provide an unlimited exposure option. Preserve existing risk limits unless a separately reviewed change explicitly alters them.

## Required verification before considering activation

1. Static regression tests: ANALYSIS_ONLY default; no accidental LIVE authorization; no martingale/averaging-down; all adds require campaign risk gate; risk-calculation failure blocks.
2. State-machine tests: initial entry, eligible add, duplicate-signal rejection, add rejection on loss, invalidation, partial fill, timeout/ambiguous result, terminal restart, close reconciliation, reversal and manual/foreign position conflicts.
3. Broker-mode tests: netting and hedging; partial fills; volume-step rounding; stop/freeze-level rejection; gaps; spread spikes; stale quotes; margin changes; disconnects.
4. MT5 compile and Strategy Tester tests with realistic costs and out-of-sample periods. Compare the single-entry baseline against pyramiding using expectancy, drawdown, profit retention, exposure and risk-of-ruin estimates.
5. Demo forward test and review results. Keep ANALYSIS_ONLY as the source default throughout. No live-trading claim until independent review and explicit authorization.

## Acceptance criteria

The feature is not complete until the campaign manager and aggregate risk gate are wired into every initial-entry/add/reversal path, tests cover the failure modes above, the EA compiles in MetaEditor, and Strategy Tester/demo evidence is recorded. A green static workflow alone is insufficient.
