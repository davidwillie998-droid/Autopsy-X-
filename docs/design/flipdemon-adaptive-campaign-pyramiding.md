# FlipDemon Extreme: Adaptive Campaign Pyramiding

Status: implementation contract, not a claim that pyramiding is implemented or validated.

## Objective

Replace the current single-position execution assumption with a campaign model that can scale into a proven trend. Order count is an execution choice, not a strategy limit. There is no arbitrary campaign entry-count ceiling. Total exposure remains bounded by broker constraints and the account-wide stop-risk coordinator.

## Required behaviour

- Cut losing trades quickly when the setup thesis is invalidated, structure breaks, or opposing momentum is confirmed. Never widen a stop to rescue a losing trade.
- Add only to a profitable campaign, never average down and never add to a losing campaign.
- Require a fresh, deduplicated continuation event for every addition.
- Prefer pullback-and-resumption entries at valid structural levels: VWAP, FVG, order block, prior breakout/retest, liquidity level, or another confirmed support/resistance reference.
- Require trend alignment and renewed directional momentum. A pullback alone is not an entry signal.
- Increase desired volume as account equity grows, but calculate actual volume from remaining account-wide stop-risk capacity, stop distance, broker volume rules, margin, spread, and execution-quality limits.
- Small accounts may use several broker-valid minimum-sized tickets when each independently qualifies. Larger accounts may use one large order or a small number of larger orders. Do not split orders to satisfy an arbitrary strategy counter.
- Broker maximum-volume-per-order and volume-step constraints may require execution splitting. Splitting must preserve the same total approved risk budget and must be reconciled after every fill.
- If a broker minimum lot would exceed the remaining risk budget, reject the addition. Never round volume upward into a risk breach.

## Sizing contract

For each proposed addition:

1. Read current equity and the configured risk policy. Existing mode risk remains unchanged: Normal 0.5%, Aggressive 1.0%, Extreme configurable but hard-capped at 2.0%.
2. Scan broker-confirmed positions and pending orders account-wide. Unknown, unprotected, or unreconciled exposure blocks new additions.
3. Compute existing stop-loss downside in account currency with OrderCalcProfit and the actual broker-confirmed stops.
4. Calculate remaining monetary risk capacity under the existing 2% aggregate hard ceiling. Do not treat floating profit as free risk budget.
5. Calculate candidate stop-risk per lot using its actual protective stop. Normalize down to broker volume steps. Reject if below minimum volume or if normalized volume exceeds remaining risk.
6. Apply margin, stop-out, spread, slippage, liquidity/impact and execution checks to the final volume.
7. Re-scan and reconcile after fills. A partial fill is managed at actual filled volume, never requested volume.

Equity growth can increase the monetary budget, but it cannot raise the configured percentage ceiling or bypass existing drawdown, daily/weekly loss, margin, or emergency controls.

## Campaign continuation gates

An addition is eligible only when all conditions hold:

- Campaign direction and thesis remain valid.
- Campaign net PnL is positive after commission, swap and known costs.
- Previous position protection is intact; no unprotected or unknown campaign leg exists.
- Price has made a favourable impulse, then retraced into a configured/validated level.
- A fresh rejection/hold and directional resumption are confirmed. Do not infer absorption or order-flow evidence when broker data is unavailable.
- Momentum is strengthening or has resumed in the campaign direction, with HTF and VWAP alignment where those filters are enabled.
- Signal identity (symbol, direction, timeframe, closed-bar timestamp or unique event sequence, and campaign ID) has not already been consumed.
- Proposed addition passes the complete existing entry, account-risk, distributed-reservation, margin and execution pipeline.

A campaign pauses additions when momentum deteriorates, price invalidates continuation structure, spread/impact becomes abnormal, drawdown protection activates, or any risk snapshot is unknown. Existing positions continue to be managed.

## Position and campaign accounting

- Introduce a durable campaign identifier and journal each entry/deal, volume, fill, protective stop, risk-at-entry, signal identity and realised costs.
- Recover campaign state after restart from broker positions/deals plus the durable journal. Broker comments may assist attribution but must not be the sole source of truth.
- Netting accounts: calculate live open risk from the actual broker net position and its current stop. Keep deal-level campaign attribution separately; never sum historical entry deals as if they were separate open positions.
- Hedging accounts: each ticket requires individual stop, partial-close, trailing, retry and recovery management. Keep the existing hedging-account rejection until the complete multi-ticket lifecycle is implemented and tested.
- Full Margin eligibility must be persisted per campaign/position in restart-safe state. Do not rely solely on a broker comment tag.

## Implementation sequence

1. Campaign journal and broker reconciliation, with restart recovery and netting/hedging distinction.
2. Profit-only continuation gate with pullback/resumption signal deduplication.
3. Equity-responsive sizing for additions, using the account-wide risk snapshot and broker volume-step rules.
4. Multi-order execution where broker limits require splitting, with per-fill reconciliation and rollback/lock behaviour.
5. Multi-ticket position management, including rapid invalidation exits and protected winner trailing.
6. Acceptance tests, CI, MetaEditor compile, and MT5 Strategy Tester scenarios. No live activation based on static tests alone.

## Acceptance criteria

- No fixed maximum campaign entry count is used as the strategy limiter.
- A single 5-, 10-, or 20-lot order is permitted only when broker limits, margin, execution quality and actual stop-risk budget all permit it. These are examples, not default lot sizes.
- Multiple small tickets are permitted only when each has a fresh qualifying continuation event and the aggregate remains within all limits.
- Duplicate ticks or repeated copies of one signal cannot create duplicate additions.
- No addition occurs while campaign net PnL is non-positive.
- No addition occurs without a valid protective stop.
- No addition occurs when account exposure is unknown or the account-wide 2% hard risk ceiling would be breached.
- No averaging down, martingale, forced minimum-lot promotion, or stop widening.
- Netting and hedging lifecycle behaviour is explicitly tested before enabling the corresponding account mode.
- Tests report actual outcomes. MetaEditor compilation and Strategy Tester evidence are reported separately from Python/static CI.

## Current implementation constraint

The existing EA has single-position state (g_haveOpenPosition, g_posState, g_positionIdentifier) and a single-position management path. Its current default caps are one open position and 1.0 gross/directional lots. Merely raising these inputs would allow states the current lifecycle cannot safely manage. Multi-position execution must remain disabled until the campaign lifecycle and reconciliation phases above are complete.