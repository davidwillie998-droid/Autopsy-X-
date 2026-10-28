# FlipDemon Extreme: Equity-Responsive Campaign Pyramiding

Status: implementation contract / test plan. This document is not evidence of compilation or trading performance.

## Objective

Support accounts of any positive equity, without a hard-coded starting deposit. Recalculate risk capacity from current equity and broker specifications. Increase campaign exposure only when new, independent continuation evidence appears and the complete account risk budget permits the add.

## Non-negotiable invariants

1. No fixed $50 or other deposit assumption. Use live account equity, free margin, broker volume min/max/step, tick size/value, contract size, stop constraints and margin calculation.
2. Never round a risk-sized volume upward to the broker minimum. If minimum volume breaches the trade risk budget, reject the entry.
3. No martingale, no averaging down, and no add to a losing campaign.
4. An add requires a new setup identity (symbol + timeframe + closed signal-bar time + direction) AND an explicit continuation-confirmation result. A new bar alone is not proof of continuation.
5. Require the campaign to be profitable by a defined R threshold before adding; calculate campaign R from recorded initial risk, not a trailing stop that has already moved.
6. Validate the proposed add with OrderCalcProfit at the proposed stop, then enforce both campaign-level and account-wide aggregate stop-risk caps.
7. Validate margin with OrderCalcMargin and account margin level/usage before every entry. Broker stop-out is never a protective control.
8. Reconcile open positions, pending orders, partial fills, closes, and reversals from MT5 broker state on init and after trade transactions. Do not trust volatile in-memory state after restart.
9. Handle netting and hedging accounts explicitly. In netting mode, multiple fills may merge into one position; campaign entries must therefore be tracked by deal/order history or durable campaign metadata, not just position count.
10. The default mode remains ANALYSIS_ONLY. Pyramiding remains disabled until compile, deterministic tests, Strategy Tester, and demo validation pass.

## Entry/add decision contract

The campaign manager returns one of: ACCEPT_FRESH_ENTRY, ACCEPT_ADD, REJECT. Every rejection includes a stable reason code.

For ACCEPT_ADD, all must be true:
- pyramiding explicitly enabled;
- fresh unique setup identity not already consumed;
- continuation detector explicitly confirms displacement/structure break and a pullback/resumption or equivalent frozen setup;
- same-direction campaign exists and is above the minimum open-profit R threshold;
- no opposing position or unresolved reversal state for that campaign;
- campaign entry count is below the configured cap (10 is a ceiling, not a target);
- proposed risk fits remaining campaign and account risk budgets;
- projected margin and exposure pass broker/account caps;
- symbol quote and score are fresh, trade mode allows execution, stop is valid and valued.

## Equity-responsive sizing

Base risk budget = current equity × configured risk percentage. The configured percentage remains subject to hard caps and account health state. Equity growth may increase currency risk budget proportionally, but a temporary floating-equity spike must not independently ratchet risk upward. Recalculate at each entry and add. During drawdown, defensive multipliers reduce risk; breached loss locks block new entries. Risk must never be increased to recover a loss.

## Deterministic acceptance test matrix

| Case | Expected result |
|---|---|
| Equity = 0.30; calculated size below broker minimum | REJECT_MIN_VOLUME_EXCEEDS_RISK; no order |
| Equity = 10 / 50 / 500 / 5000; same normalized setup and broker metadata | Risk budget scales with equity; no fixed-deposit branch |
| Raw lot falls between volume steps | Round down to valid step |
| Minimum lot's OrderCalcProfit stop loss exceeds per-trade budget | Reject, even if margin is available |
| No open campaign, fresh valid signal | Evaluate as new entry, not an add |
| Existing same-direction campaign is losing | Reject add |
| Existing campaign is profitable but no fresh continuation confirmation | Reject add |
| Same setup ID repeated on subsequent ticks | Reject duplicate |
| New closed-bar setup with valid continuation | May proceed to risk/margin gates |
| Proposed add breaches aggregate account stop-risk cap | Reject add |
| Proposed add breaches campaign risk cap | Reject add |
| Margin calculation fails or margin headroom is inadequate | Reject add |
| Existing position/pending order has missing SL or risk cannot be valued | Fail closed; reject new entries |
| Opposing position/reversal is active | Reject add |
| Partial fill | Reconcile actual filled volume and actual risk |
| EA restart with live positions | Rebuild campaign state from broker state/history before entries |
| Netting account merges multiple deals | Preserve campaign entry count and risk through deal/history metadata |
| Hedging account has separate tickets | Aggregate all matching tickets by campaign and direction |
| Equity falls or daily/weekly lockout trips | Reduce/block new entries; never raise size to recover |
| Maximum campaign entry count reached | Reject further adds |
| Analysis-only mode | No order submission regardless of signal |

## Required validation evidence before enabling pyramiding

- MetaEditor compile output, including compiler version and zero-error result.
- Deterministic tests for every row above.
- MT5 Strategy Tester runs on supported account modes and symbols, with spread/commission/slippage assumptions documented.
- Demo forward test confirming restart recovery, partial fills, risk accounting, and that every add follows a fresh continuation setup.
- Recorded expectancy, drawdown, profit factor, trade count, and out-of-sample results. Passing CI alone is not profitability evidence.
