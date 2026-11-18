# AX IQ200-00/01: Execution Baseline and Telemetry Contract

**Status:** Contract defined. Telemetry implementation is not yet complete.  
**Deployment:** Analysis-only observation. No order-routing authority.  
**Target branch:** `claude/autopsy-flipdemon-extreme-l4ei3d`

## 1. Purpose and scope

AX IQ200 is an execution-quality layer for orders that have already passed the strategy and risk gates. It does not generate direction, approve a setup, change volume, move stops, or decide whether a campaign may add exposure.

IQ200-00 establishes the baseline and data contract. IQ200-01 implements event capture and persistence. This document is the contract both phases must satisfy.

The initial telemetry release must not:
- submit, modify, cancel, or close an order;
- alter W1 institutional direction, D1 structural levels, H4 confirmation, or lower-timeframe entry rules;
- change campaign direction, pyramid eligibility, or profitable-only add rules;
- change position sizing, stop placement, aggregate exposure, or the immutable 2% account-wide risk ceiling;
- weaken distributed reservation, idempotency, recovery, or fail-closed behavior;
- enable live execution. `AX_MODE_ANALYSIS_ONLY` remains the default.

## 2. Existing implementation baseline

The inspected branch already contains:
- `ExecutionQualityJournal.mqh`, an append-only CSV journal with 13 columns and only `ENTRY` / `EXIT` event types;
- `ExecutionLatencyProfiler.mqh`, a 256-sample rolling profiler for local `OnTick` and synchronous execution-call elapsed time;
- `SpreadCostIntelligence.mqh`, which tracks rolling spread and empirical slippage statistics;
- `OnTradeTransaction` handling and broker-history recovery for campaign intents;
- execution and risk modules that must remain the sole authorities for broker requests and risk permission.

The current quality journal performs file writes and flushes synchronously in `Record()`. It does not yet describe the full order lifecycle, partial fills, broker acknowledgements, cancellations, rejections, expiry, or post-fill markouts. The existing latency profiler measures local terminal elapsed time, not one-way network latency.

**Implementation decision:** preserve the existing journal and its consumers. Add a separate versioned IQ200 telemetry stream with a bounded in-memory queue and controlled flush outside the hot tick and trade-transaction paths. Do not silently change the existing 13-column file format.

## 3. Event contract

Each event is one immutable record. Events are correlated by `session_id`, `decision_id`, `intent_id`, `order_ticket`, `deal_ticket`, `position_identifier`, and `campaign_id` where those identifiers are known. Unknown identifiers are zero or empty, never fabricated.

Required event types:

| Event | Meaning |
|---|---|
| `DECISION` | A strategy-approved execution candidate reaches the execution boundary. |
| `ROUTE_PLAN` | The current execution path selects its existing order method. This is observational only. |
| `ORDER_SUBMITTED` | A broker request is actually sent. |
| `BROKER_ACK` | Broker response is received and classified. |
| `DEAL_PARTIAL` | A confirmed partial fill is observed. |
| `DEAL_FILLED` | A confirmed fill is observed. |
| `ORDER_CANCEL_REQUESTED` | A cancellation request is sent. |
| `ORDER_CANCELLED` | Cancellation is confirmed by broker state/history. |
| `ORDER_REJECTED` | A definitive rejection is confirmed. |
| `ORDER_EXPIRED` | Expiry is confirmed from broker state/history. |
| `ORDER_AMBIGUOUS` | The outcome cannot safely be classified yet. |
| `POSITION_CLOSED` | A closing deal or confirmed position closure is observed. |
| `MARKOUT` | A scheduled post-fill market observation is captured. |
| `QUEUE_OVERFLOW` | Telemetry records were dropped because the bounded queue was full. |

A request return code alone must not be treated as proof of a fill. Distinguish request submission, broker acceptance, order existence, deal execution, and position confirmation. Preserve the existing conservative classification of accepted, rejected, and ambiguous outcomes.

## 4. Record schema

Schema version: `1`. The serialized representation must be stable and explicitly versioned.

| Field | Type / unit | Rule |
|---|---|---|
| `schema_version` | integer | Must equal 1 for this contract. |
| `event_id` | unsigned integer or stable token | Unique within the terminal journal. |
| `event_type` | enum string | One of the event types above. |
| `event_time_msc` | integer milliseconds | Broker/server event time when available; otherwise terminal time with source flag. |
| `time_source` | enum | `BROKER`, `TERMINAL`, or `ESTIMATED`. |
| `session_id` | string | New terminal-session identifier, persisted for restart correlation. |
| `decision_id` | string | Stable ID for one approved execution candidate. |
| `intent_id` | string | Existing durable intent token when available. |
| `campaign_id` | string | Existing pyramid campaign identity when available. |
| `symbol` | string | Exact broker symbol, including suffix. |
| `magic` | unsigned integer | EA magic number. |
| `direction` | enum | `BUY`, `SELL`, or `NONE`. |
| `order_type` | enum | Actual request type, or `UNKNOWN`. |
| `requested_volume` | lots | Requested volume, not normalized or inferred volume. |
| `confirmed_volume` | lots | Broker-confirmed cumulative deal volume at event time. |
| `requested_price` | price | Zero only when not applicable or unavailable. |
| `fill_price` | price | Confirmed deal price; never substitute requested price. |
| `bid`, `ask` | price | Quote snapshot captured at decision/submission/fill where available. |
| `spread_points` | points | Derived from the same quote snapshot and symbol point size. |
| `point_size`, `tick_size` | price units | Captured to make point-based fields interpretable. |
| `atr_points` | points | Value and timeframe used by the current strategy at decision time, if available. |
| `regime`, `volatility_state` | integer/enum | Existing classifier outputs, with explicit missing flags. |
| `spread_percentile` | percentile | Existing spread intelligence output, if available. |
| `slippage_points` | points | Signed fill minus decision/reference price, normalized by direction; retain raw signed value too. |
| `local_elapsed_us` | microseconds | Terminal-local elapsed time only. |
| `retcode` | integer | Broker return code when supplied. |
| `retcode_external` | integer | External return code when supplied. |
| `reason_code` | enum/string | Stable internal classification, not free-form prose. |
| `feature_mask` | bit mask | Indicates which optional feature groups were present. |
| `model_version` | string | Empty until a validated model is introduced. |
| `reserved_risk_amount` | account currency | Observed reservation amount, if available. Read-only telemetry. |
| `markout_horizon_ms` | integer | Set only for `MARKOUT`. |
| `markout_points` | points | Direction-adjusted post-fill movement from confirmed fill price. |

Missing values must be represented explicitly through a missingness mask or documented sentinel. Zero must not ambiguously mean both a real zero and unavailable data. Avoid account numbers, credentials, API keys, or other secrets in the journal.

## 5. Feature snapshot contract

At `DECISION` time, capture only data already available to the EA. Candidate fields include:
- bid, ask, spread, point size, tick size, quote age and quote-validity;
- ATR and realized-volatility proxy, with timeframe and lookback;
- tick arrival rate and signed tick imbalance, with sample count;
- rolling spread median, p95 and spread-to-ATR ratio from the existing spread module;
- W1 direction, D1 structural state, H4 regime/breakout state and current entry timeframe;
- current strategy score/confidence and the selected direction;
- existing order-flow/footprint/volume-profile features and their availability flags;
- broker DOM availability and snapshot age, where supplied by the terminal;
- session/time bucket and broker symbol specification;
- current order method and urgency/deadline metadata, only where those concepts already exist.

Do not fabricate exchange queue position from retail DOM snapshots. Do not label tick volume as traded volume. Missing DOM or unavailable broker data must be explicit, not silently replaced with zero.

## 6. Fill and outcome labels for later model training

A future fill-probability model must define a fixed observation horizon before labels are generated. A passive order that is cancelled before the horizon is censored or assigned a documented cancellation reason; it is not automatically a negative fill. A price touching a limit is not proof of execution.

Training records must distinguish:
- confirmed full fill;
- confirmed partial fill;
- confirmed non-fill at horizon;
- cancelled by policy;
- expired;
- rejected;
- ambiguous/unreconciled;
- censored due to missing or interrupted observation.

Post-fill markouts should initially use fixed horizons such as 1s, 5s, and 30s, subject to symbol tick frequency and reliable quote availability. Each markout must reference the actual confirmed deal price and a valid later quote. Direction-adjusted markout is positive when the market moves in the trade's favor.

## 7. Buffering and persistence requirements

- Capture events into a fixed-capacity in-memory ring buffer.
- Do not perform file I/O, network I/O, model inference, or expensive sorting in `OnTick` or `OnTradeTransaction`.
- Flush from `OnTimer` or another controlled non-hot-path callback.
- Use append-only records with schema version and deterministic escaping/encoding.
- Verify write length and flush outcome. Latch telemetry persistence unhealthy after an unrecoverable write error and report it.
- On queue overflow, increment a counter and emit/retain an overflow diagnostic when capacity becomes available. Never block trading to preserve telemetry.
- On restart, start a new session ID and preserve event IDs without pretending the in-memory queue survived a crash.
- Telemetry failure must not grant trade permission, change a risk result, or weaken fail-closed behavior. It may reduce research-data completeness only.

## 8. Baseline measurements

Before any IQ200 router or model is enabled, collect a baseline under the existing execution method, grouped by symbol, session, spread regime, volatility regime, and order direction.

Required metrics:
- request-to-broker-response elapsed time, clearly labeled terminal-observed elapsed time;
- decision-to-confirmed-fill elapsed time;
- fill ratio, partial-fill ratio, rejection ratio, cancellation ratio and ambiguous-outcome ratio;
- requested versus confirmed volume;
- signed and absolute slippage, median, p90 and p95;
- spread at decision and at fill;
- post-fill markout at each configured horizon;
- execution cost in points and account currency where commission/swap data is reliable;
- telemetry completeness, dropped-event count and journal persistence failures.

Report sample counts beside every statistic. Do not compare groups with materially different sample sizes without showing the counts. Do not claim a network one-way latency measurement from local terminal timers.

## 9. Acceptance gates

IQ200-01 is complete only when all of the following are demonstrated:

1. Existing 13-column execution journal remains backward-compatible.
2. New event schema has versioned serialization and deterministic parsing tests.
3. Event IDs and correlation IDs remain stable across the full observed order lifecycle.
4. Partial fills and multiple deals are recorded without double-counting cumulative volume.
5. Ambiguous broker outcomes remain ambiguous until reconciled; telemetry never reclassifies them.
6. The ring buffer has bounded memory and deterministic overflow behavior.
7. File flush occurs outside `OnTick` and `OnTradeTransaction`.
8. Persistence errors are observable and do not alter risk or order decisions.
9. Static checks verify that telemetry has no order-send, modify, cancel, close, sizing, stop, or reservation-authority calls.
10. Existing account-risk, reservation, restart-recovery, W1/D1/H4, and pyramid tests remain green.
11. CI evidence is recorded. Native MetaEditor compilation and MT5 Strategy Tester validation are reported separately and only when actually run.

## 10. Next implementation sequence

1. Add schema definitions and a pure serializer/parser with unit tests.
2. Add the bounded telemetry buffer and controlled flush lifecycle.
3. Connect decision and request events at existing execution boundaries.
4. Connect broker transaction events without changing their current reconciliation behavior.
5. Add markout scheduling only after fill-event correlation is proven.
6. Produce a baseline report from collected demo data.
7. Only then proceed to offline fill-probability and adverse-selection research.

No IQ200 model, limit-order router, reprice policy, or live execution change is authorized by this phase.
