# FlipDemon Extreme HFT — Pyramid Demo Forward-Test Protocol

## Scope

This protocol covers the standalone MQL5 FlipDemon Extreme HFT Expert Advisor.
It does not describe or modify AUTOPSY X.

The first campaign-execution rollout is restricted to MT5 **DEMO** accounts and
NETTING or EXCHANGE margin modes. Hedging-account pyramid execution remains
blocked until ticket-specific multi-leg exits, stop management and recovery
are implemented and validated.

## Current source controls

- `InpEnablePyramidDecision=true`: evaluate profitable continuation candidates.
- `InpEnablePyramidExecution=false`: broker add-on orders remain opt-in.
- `InpExecutionMode=AX_EXEC_ANALYSIS_ONLY`: default mode sends no orders.
- The pyramid order function requires `AX_EXEC_LIVE` plus explicit pyramid opt-in.
  On a demo account, AX_EXEC_LIVE means broker execution is enabled against the
  demo server. It does not authorize real-account execution.
- The pyramid order function independently checks
  `ACCOUNT_TRADE_MODE_DEMO`. Real and contest accounts are rejected.
- The first rollout supports NETTING and EXCHANGE margin modes only.
- The campaign add uses the broker-confirmed campaign stop and current position
  identity. It does not average down or add to an unprofitable campaign.
- Account-wide stop-risk remains subject to the immutable 2% equity ceiling.
- Broker margin preflight runs before the account mutex and is repeated using a
  fresh quote while the mutex is held, immediately before the final risk check.
- A central risk reservation is required before order submission. The execution
  uncertainty marker is persisted before the broker request. Exact broker deals,
  the resulting net position and a fresh post-fill risk snapshot are reconciled
  before the campaign can become ready for another tier.
- An uncertain broker outcome is quarantined. The EA must not blindly resubmit.

## Required demo configuration

Use a dedicated demo account with no unrelated open positions or pending orders
during the first test. Use one chart, one symbol and one EA instance.

1. Compile `MQL5/Experts/AutopsyX/AutopsyX_FlipDemon_Extreme.mq5` in MetaEditor.
   Resolve every compiler error and warning before attaching it.
2. Confirm the terminal account is labelled DEMO and the account margin mode is
   NETTING or EXCHANGE.
3. Configure the persistent distributed-risk service URL and key. If it is not
   configured and reachable, the EA must remain fail-closed.
4. Start with `InpMode=AX_MODE_NORMAL` to exercise the 5% margin-utilisation
   profile. This is a margin-usage limit, not a stop-loss risk percentage.
5. Keep the 2% account-wide monetary stop-risk ceiling unchanged.
6. Start with `InpPyramidMaxTiers=2`, `InpPyramidLotMultiplier=1.5`,
   `InpPyramidAtrGapMultiplier=0.75`, and the existing minimum-profit rule.
7. First attach with `InpEnablePyramidExecution=false`. Confirm the EA
   initializes, recovers the campaign registry, and logs qualifying candidates
   without submitting add-on orders.
8. Only after the compile and candidate-only checks pass, set
   `InpExecutionMode=AX_EXEC_LIVE` and `InpEnablePyramidExecution=true`
   on that confirmed demo account. The source-level DEMO check remains
   authoritative and blocks real/contest accounts.

Do not use a real account for any stage of this protocol.

## Staged forward test

### Stage 0 — compile and startup

Record the MetaEditor build number, compiler output, broker server, account
mode, margin mode, account currency, symbol contract size, tick size/value,
volume min/max/step, stop/freeze levels and supported filling mode.

Pass criteria:
- Zero compiler errors and warnings.
- Startup broker/symbol preflight succeeds.
- Campaign registry and restart recovery report ready.
- Account-wide risk snapshot is known and within budget.
- Distributed risk service is reachable and reconciled.
- No campaign order is sent.

### Stage 1 — candidate-only observation

Keep pyramid execution disabled. Observe at least one complete qualifying
continuation candidate, or continue until market conditions produce one.
Do not manufacture a signal or force an entry.

Record the completed H1 bar, campaign direction, last confirmed tier fill,
ATR gap, basket profit, proposed tier volume and projected aggregate risk.

Pass criteria:
- Only completed H1 data is used for trend and ATR.
- Campaign must be profitable and directionally valid.
- Candidate must clear the configured continuation gap.
- Candidate volume must exceed the prior confirmed tier volume and satisfy
  broker min/max/step/volume-limit rules.
- No order is submitted while execution is disabled.

### Stage 2 — one demo add-on

Enable execution on the demo account with the maximum campaign tiers set to 2.

Pass criteria for every add:
1. Demo account and supported netting/exchange mode are confirmed.
2. Campaign ticket, stable position identifier, direction and protective stop
   match the broker position.
3. Current quote and spread are valid.
4. Broker volume contract preflight passes.
5. Initial and locked, fresh-quote `OrderCalcMargin` checks pass.
6. Projected margin usage and margin level remain inside configured limits and
   the broker stop-out buffer.
7. The account mutex is acquired.
8. The final account-wide stop-risk evaluation remains at or below 2% of equity.
9. Distributed reservation succeeds and its uncertainty marker is durable.
10. The exact order's broker entry deals and resulting net position are confirmed.
11. The post-fill account snapshot is known, within the hard cap, and centrally
    settled.
12. The campaign registry is reconstructed from broker deal history before
    another add is considered.

A failed or ambiguous step must block further campaign additions. An ambiguous
submission must never be automatically retried.

### Stage 3 — controlled multi-tier campaign

Only after Stage 2 passes, raise the maximum tier count gradually, never beyond
the configured five-tier ceiling. Each tier must be a fresh qualifying
continuation, not a timed or unconditional scale-in.

Pass criteria:
- Every confirmed tier has a unique broker order/deal identity.
- Tier count and last-tier fill price/volume reconcile after each add.
- No duplicate add occurs on the same completed H1 bar.
- Aggregate stop-risk never exceeds 2% of current equity.
- Margin and stop-out buffers pass at the actual submission point.
- No add occurs after a loss, invalid stop, unknown exposure, stale quote,
  reservation conflict, recovery failure or account-risk lock.

## Mandatory negative tests

Run each test on demo before considering any broader rollout:

- Switch account to REAL or CONTEST: pyramid order function must refuse execution.
- Use a hedging account: pyramid add must remain blocked.
- Reduce free margin so the add fails projected margin: no order sent.
- Move projected margin level inside the broker stop-out buffer: no order sent.
- Exhaust the remaining 2% stop-risk budget: no order sent.
- Remove or invalidate the campaign stop: no order sent.
- Widen spread beyond the configured limit: no order sent.
- Make broker volume fall below minimum or violate volume step/limit: no order sent.
- Disable or disconnect the distributed coordinator: no order sent.
- Simulate definitive broker rejection: reservation is released only after a
  fresh known broker snapshot.
- Simulate timeout/connection loss after submission: reservation and local
  uncertainty state remain locked until exact broker reconciliation.
- Restart MT5 after a confirmed add: campaign tiers rebuild from exact broker
  deal history before another add.
- Restart MT5 with an unresolved submission: no duplicate add is sent.
- Close or partially close the campaign externally: broker volume/deal history
  must reconcile before the campaign can scale again.

## Evidence log

For each candidate and attempted add, retain:
- UTC timestamp and completed H1 bar time.
- Broker server, demo account mode, symbol and margin mode.
- Equity, balance, free margin, margin used and margin level.
- Current position identifier, ticket, direction, volume and protective stop.
- Campaign tier before and after the event.
- Requested volume and broker-confirmed filled volume.
- Quote, spread, required margin and projected margin metrics.
- Existing stop-risk, proposed add risk, aggregate stop-risk and 2% budget.
- Distributed reservation ID and settlement result.
- Exact order ticket and entry deal tickets.
- Execution retcode, fill price, slippage and latency.
- Recovery/reconciliation state and any rejection reason.

## Evidence boundary

The repository's Python tests and static safety workflow are not an MT5 forward
test. They do not execute MQL5, connect to a broker, observe live demo ticks or
confirm real fills.

A demo forward-test is complete only when the compiled EA has run on a connected
broker demo account and the Journal, Experts log and broker deal history provide
the evidence listed above. Until then, status is **WIRED FOR CONTROLLED DEMO
VALIDATION, FORWARD TEST NOT YET RUN**.
