# Shadow River / Directional-Change Intelligence — Research Specification

**Project:** AUTOPSY X — FlipDemon Extreme  
**Target branch:** `claude/autopsy-flipdemon-extreme-l4ei3d`  
**Baseline inspected:** `e92aac2b707f18188cdb04c112de58d1de1abd0b`  
**Status:** Research specification only. Not compiled, not wired into the EA, and not authorized to submit orders.

## 1. Research question

Does an event-driven directional-change representation add measurable, out-of-sample information to FlipDemon's existing tick momentum, microstructure, liquidity, regime, VWAP and flip-confirmation signals, after realistic XAUUSD transaction costs?

The objective is not to maximize tick count, order count or trade frequency. It is to improve the timing and quality of a small number of eligible decisions.

## 2. Evidence and limitations

- The Shadow River Chart material describes price-distance steps and opposite-distance reversal confirmation. Treat its published thresholds as a hypothesis, not a validated optimum.
- Directional-change (DC) sampling records price events when movement from an established extreme crosses an observer-defined threshold. A reversal is only confirmed after the threshold is crossed; the final extreme is not knowable at the time it occurs.
- The 2024 study *Nowcasting directional change in high frequency FX markets* investigates estimating a change before its confirmation point. This supports research into a provisional early-warning score, not treating an unconfirmed reversal as fact.
- MetaTrader 5's `OnTick` event is not a guaranteed one-callback-per-market-tick stream: a new NewTick event is not queued while one is already queued or being processed. `CopyTicks` provides a way to retrieve terminal tick history and recover batches for analysis.
- `OrderSendAsync` returning success means the request was sent, not that the server accepted or filled it. Broker-side outcomes must be reconciled through trade transactions and actual positions/deals.

Primary references:
- https://onlinelibrary.wiley.com/doi/10.1002/isaf.1552
- https://www.mql5.com/en/docs/event_handlers/ontick
- https://www.mql5.com/en/docs/series/copyticks
- https://www.mql5.com/en/docs/trading/OrderSendAsync
- https://www.mql5.com/en/docs/event_handlers/ontradetransaction

## 3. Proposed engine boundary

Create a standalone, deterministic, signal-only engine named `ShadowRiverEngine` (Python reference first, MQL5 port second).

Inputs per ordered quote:
- broker/server timestamp with millisecond precision where supplied;
- Bid and Ask, validated as positive and non-crossed;
- symbol point and tick size;
- completed-bar ATR or another explicitly timestamped volatility estimate;
- quote sequence/source metadata and a data-quality status.

Use midpoint `(Bid + Ask) / 2` as the default event-price series to reduce bid/ask bounce. Retain Bid, Ask and spread separately for execution-cost analysis. Never infer traded volume from quote count and label tick-count proxies as proxies.

The engine must not read future bars, revise past confirmed events, call trade APIs, size positions, change risk, or authorize entries.

## 4. Event state machine

Maintain:
1. `SEEKING_EXTREME`: track the running high while the active direction is upward, or running low while downward.
2. `REVERSAL_CANDIDATE`: price has moved against the tracked extreme but has not crossed the full confirmation threshold.
3. `CONFIRMED_DIRECTION_CHANGE`: adverse movement from the tracked extreme reaches the configured threshold. Emit a timestamped event and start tracking the new direction.
4. `STALE_OR_INVALID`: quote age, sequence continuity, spread sanity or volatility input fails validation. Emit no directional event until valid data resumes.

Store both the extreme timestamp and confirmation timestamp. Never timestamp a confirmed reversal at the earlier extreme. Keep provisional nowcast scores separate from confirmed events.

## 5. Adaptive threshold, not fixed pips

Research the threshold as a bounded function of observable conditions:

`threshold = max(min_tick_distance, ATR_completed_bar * atr_multiplier, current_spread * spread_floor_multiplier)`

Requirements:
- All terms must be converted to price units consistently.
- ATR must come from a completed bar available at the decision timestamp.
- Apply configured lower and upper bounds to prevent thresholds collapsing in quiet markets or exploding during shocks.
- If spread exceeds the configured maximum or quote quality is invalid, mark the sample unavailable rather than widening the threshold until the market appears tradable.
- Evaluate fixed-distance, ATR-only and hybrid thresholds as separate baselines.
- Do not optimize one threshold on the full sample.

The initial values are experimental parameters, not production defaults.

## 6. Features to expose (observational only)

- active direction and state;
- distance from current price to tracked extreme;
- reversal progress as a fraction of the current threshold;
- elapsed milliseconds and tick count since the extreme;
- event displacement in points and ATR units;
- pre-confirmation retracement velocity and acceleration;
- threshold version and ATR timestamp;
- quote age, spread, and data-quality flags;
- confirmed event time, extreme time and confirmation delay;
- optional nowcast score with explicit `UNAVAILABLE` state and calibration metadata.

A nowcast score must not be named or displayed as a probability unless calibration is independently demonstrated.

## 7. Integration proposal

**Phase A — Python research reference**
- Implement the state machine with deterministic replay.
- Add prefix-invariance tests: appending future ticks must not alter prior outputs.
- Add duplicate timestamp, out-of-order tick, missing tick, crossed quote, zero quote, stale quote, spread spike, gap, equal-price and extreme-volatility tests.
- Verify price-scale invariance when all price quantities (including tick size, spread and ATR) are scaled consistently.
- Verify that a reversal is emitted only at the threshold-crossing observation, never at the prior extreme.

**Phase B — XAUUSD historical evaluation**
- Use broker-specific bid/ask tick data, not mid-only bars.
- Preserve source, timezone, symbol specification and data coverage.
- Split chronologically into development, validation and untouched test periods.
- Compare current FlipDemon baseline against baseline + DC events, then baseline + DC + nowcast.
- Report net expectancy in R, drawdown, trade count, turnover, false reversal rate, missed move rate, adverse excursion, fill/slippage sensitivity and confidence intervals.
- Include spread, commission, swaps where applicable, and conservative slippage. A zero-spread run is a diagnostic lower bound only, never the primary result.
- Run ablations by session, volatility regime, spread regime and long/short direction.
- Correct for multiple threshold/parameter trials and retain an experiment ledger.

**Phase C — MQL5 parity port**
- Port only after Python behavior and acceptance criteria are frozen.
- Compare Python and MQL5 outputs event-by-event on identical ordered tick fixtures.
- Use `CopyTicks` with a persistent last-processed timestamp/sequence strategy to recover ticks that were not individually surfaced through `OnTick`; handle overlapping batches and duplicate timestamps idempotently.
- Keep event processing bounded. Do not run expensive history synchronization or large scans inside every tick callback.
- If the tick stream has a gap that cannot be reconstructed, mark the event state invalid and re-seed; do not fabricate continuity.

**Phase D — shadow observation**
- Compile and run in `ANALYSIS_ONLY` first.
- Log DC events beside existing signals without changing scores, entries, exits, lot sizes or risk.
- Promote only after parity, replay, Strategy Tester and forward-demo evidence meets predeclared acceptance criteria.

## 8. Execution architecture findings to preserve

- Keep one execution authority and one account-wide risk authority.
- Do not equate order submission with accepted order, deal, or open position.
- Treat trade transaction notifications as asynchronous and potentially non-one-to-one with requests. Keep handlers short and reconcile actual broker state.
- Do not burst orders to imitate a vendor's advertised trade count. Throughput is subordinate to broker limits, margin, exposure reservations, fill quality and idempotency.
- Never bypass the existing hard 2% aggregate risk ceiling, fail-closed reservations, restart recovery, or `ANALYSIS_ONLY` default.
- Zero spread must never be substituted for the observed Bid/Ask spread or actual commissions/slippage in a live decision.

## 9. Acceptance gates

The engine remains research-only unless all are true:
1. Python unit, property and prefix-invariance tests pass.
2. No future-data or timestamp look-ahead is detected.
3. Python/MQL5 parity is exact within explicitly defined floating-point tolerances.
4. Historical evaluation includes realistic transaction costs and untouched out-of-sample data.
5. Incremental performance is positive after costs with uncertainty reported; a higher win rate alone is insufficient.
6. No increase in risk authority, lot sizing authority, order frequency limits or live execution permissions.
7. Analysis-only shadow logs demonstrate stable data quality and no duplicate/reordered event corruption.

## 10. Explicit non-goals

- No claim that Shadow River Chart or directional-change methods are profitable.
- No copying of vendor marketing claims or unverified performance.
- No zero-spread assumptions for primary results.
- No 1,000-order-per-minute target.
- No martingale, averaging down, forced broker-minimum lot promotion, or account-risk expansion.
- No wiring into the production signal or execution path in this phase.
