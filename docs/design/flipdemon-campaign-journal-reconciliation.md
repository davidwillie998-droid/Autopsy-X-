# FlipDemon Extreme: Campaign Journal and Broker Reconciliation

Status: implementation contract. This document does not claim that campaign journaling, multi-position execution, or restart-safe pyramiding is implemented.

## Findings from the active branch

The current code already contains useful recovery infrastructure, but it solves a narrower problem:

- `RestartRecovery.mqh` stores active broker position ticket, stable position identifier, setup ID, symbol, direction, and entry time. It rewrites a small registry through a temporary file and fails closed on malformed or unreadable records.
- The registry is capped at `AX_RECOVERY_MAX_ENTRIES = 64`. It is scoped by EA name, chart symbol, and magic number. It does not store campaign IDs, individual deal fills, actual per-deal volume/price, risk-at-fill, signal identity, or realized costs.
- `TradeReconciliation.mqh` classifies transaction callbacks and reads deal history for logging. It is not a durable deal journal and does not rebuild campaign attribution.
- The main EA still owns one runtime position state (`g_haveOpenPosition`, `g_posState`) and one-symbol execution management. The existing hedging-account rejection must remain.
- `CExecutionEngine::OpenMarket` confirms the resulting symbol position. On a netting account, that aggregate position is not a substitute for the individual broker deal that filled an entry.

These components must be reused where appropriate. Do not treat the existing setup registry as proof that campaign accounting is complete.

## Source-of-truth hierarchy

1. Broker positions are authoritative for current open exposure and current stop-risk.
2. Broker deal history is authoritative for executed fills, partial fills, reversals, and realized deal costs, subject to the history range supplied by the broker.
3. The local campaign journal supplies strategy attribution: campaign ID, signal key, initial thesis, and the EA's intended association between fills and campaigns.
4. Broker comments are diagnostic hints only. They are not the sole attribution key.
5. Requested order volume, request price, and callback arrival order are never treated as confirmed fills.

The journal is an attribution ledger, not the account-risk calculator. The account-wide risk scan continues to calculate current exposure from broker-confirmed positions and remaining pending-order volume.

## Durable journal contract

The campaign journal is append-only. Each event must be independently identifiable and validated before it can affect recovered state.

Required envelope:
- schema version;
- account login and broker server identity;
- EA magic number;
- monotonically increasing journal sequence;
- event type;
- broker event time;
- integrity checksum over the serialized record.

Required campaign/leg attribution fields when applicable:
- campaign ID;
- signal key;
- symbol and direction;
- broker order ticket;
- broker deal ticket;
- stable position identifier;
- current position ticket when available;
- actual filled volume and fill price;
- protective stop at fill and risk-at-fill in account currency;
- commission, swap, fee, and realized profit when supplied by broker history;
- Full Margin eligibility state where applicable.

Use stable, delimiter-safe identifiers. Reject malformed rows, unsupported schema versions, account/server/magic mismatches, duplicate sequence numbers, conflicting duplicate deal identities, invalid numeric values, and checksum failures. Never silently skip a corrupt row and then declare recovery complete.

A successful append must flush and close the file before the journal reports durable success. If persistence fails, new entries and campaign additions remain blocked. Existing broker positions continue under whatever independently verified protective management is available.

The journal must not use a fixed campaign-entry ceiling. Any bounded in-memory cache is an implementation detail and must not truncate the durable history or silently discard active campaign attribution.

## Transaction capture and history backfill

- Treat `TRADE_TRANSACTION_DEAL_ADD` as a notification to inspect broker history, not as a complete fill record by itself.
- Select the deal and read its actual symbol, magic, entry type, order ticket, deal ticket, position ID, direction, volume, price, time, commission, swap, fee, and profit.
- Deduplicate by account identity plus deal ticket. Repeated callbacks for the same deal must be idempotent.
- Persist only after the complete deal record has been read and validated.
- If history is temporarily unavailable, mark reconciliation pending and retry. Do not fabricate a fill from request/result fields.
- On startup, select broker history from the last durable checkpoint with overlap, replay missing deals, and deduplicate by deal ticket. A checkpoint is advanced only after all events in its range are durably recorded.
- Callback order is not a reliable chronological order. Use broker deal time and stable identifiers for replay, while preserving the original callback observation time separately if needed.
- Partial fills create separate deal records. The managed quantity is the sum of broker-confirmed fills reconciled against the current broker position, never the requested order volume.

## Netting and hedging rules

### Netting

- The current broker net position for a symbol is the sole live open-risk object for that symbol.
- Do not sum historical entry-deal risk as if each entry deal were still an independent open position.
- Keep deal-level campaign attribution separately so a net position can contain multiple campaign legs or entry deals without corrupting live risk.
- Reconcile `DEAL_ENTRY_IN`, `DEAL_ENTRY_OUT`, and `DEAL_ENTRY_INOUT` explicitly. An `INOUT` reversal is a close/reversal event, not a simple additional entry. Do not allocate its close/open portions heuristically when broker history or volume accounting is ambiguous.
- Compare reconstructed deal volume and direction with the broker's current net position. Any unexplained residual, missing deal, or identity conflict marks attribution unknown and blocks new campaign additions.

### Hedging

- Every broker ticket is a separate open-risk and management object.
- Each ticket needs individual stop, partial-close, trailing, retry, close, and restart recovery state.
- Keep hedging-account rejection in place until that complete lifecycle and its tests exist. A journal alone does not make hedging safe.

## Recovery states

Recovery must return one explicit status:
- `READY`: journal validates and broker positions/deals reconcile without unexplained exposure.
- `PENDING_HISTORY`: broker history is temporarily unavailable; no new entries/additions.
- `UNTRACKED_POSITION`: broker position exists without trustworthy campaign attribution; manage defensively, block additions.
- `ORPHAN_JOURNAL_RECORD`: active journal attribution has no matching broker position/deal lifecycle; reconcile history before clearing.
- `CORRUPT_JOURNAL`: malformed, truncated, checksum-invalid, duplicate-conflicting, or identity-mismatched journal; block new entries.
- `BROKER_MISMATCH`: reconstructed volume/direction or position identity disagrees with broker state; block new entries.

Do not clear an orphan or unknown record merely because it is inconvenient. Resolve it from broker history or keep the account in a blocked recovery state.

## Acceptance tests before EA integration

1. A broker deal is attributed to the correct campaign and leg after restart.
2. Replaying the same deal twice creates one durable attribution.
3. A partial fill records actual filled volume, not requested volume.
4. A netting position's live risk is calculated once from the actual net position and current stop, not by summing historical entry deals.
5. Deal-level campaign attribution remains available when several entry deals contribute to one net position.
6. A netting `INOUT` reversal is classified separately and ambiguous allocation blocks additions.
7. Hedging tickets remain distinct risk objects; hedging execution remains disabled until management tests pass.
8. A broker position without journal attribution enters `UNTRACKED_POSITION` and blocks additions.
9. A journal record without a matching broker lifecycle enters `ORPHAN_JOURNAL_RECORD` until history resolves it.
10. A checksum failure, malformed row, truncated final row, account mismatch, or duplicate conflicting deal blocks recovery.
11. A history-cache miss enters `PENDING_HISTORY`, not a fabricated zero-volume or zero-PnL record.
12. Restart replay with overlapping history is idempotent and does not double count costs or fills.
13. Account-wide stop-risk continues to use broker positions and pending-order remainder, with the 2% hard ceiling unchanged.
14. Full Margin permission is recovered from durable state, not inferred solely from a broker comment.

## Integration order

1. Implement the append-only journal and schema validation as an isolated component.
2. Add a broker-history replay/reconciliation component and reference tests.
3. Connect the journal to the existing `OnTradeTransaction` path and startup recovery.
4. Make campaign state recoverable before enabling any additional entry.
5. Replace single-position runtime management only after ticket/deal attribution, close/partial-close handling, and restart recovery are complete.
6. Keep `ANALYSIS_ONLY` as the default. No increase to position caps, no hedging enablement, and no live activation until MetaEditor compilation and MT5 Strategy Tester evidence are recorded.

## Non-negotiable risk controls

- The account-wide stop-risk ceiling remains 2%.
- No averaging down, martingale, forced minimum-lot promotion, or stop widening.
- Additions require positive campaign net PnL after known costs, a fresh continuation signal, intact structure, resumed momentum, and protection on every managed leg.
- Unknown or unreconciled exposure blocks new entries and additions.
- Cut losing trades when the thesis is invalidated, while recognizing that gaps and execution latency can prevent an exact stop fill.

## Current implementation progress (2026-11-04)

- `CampaignJournal.mqh` provides an isolated append-only deal ledger with account/server/magic identity, monotonic sequence, checksum validation, duplicate deal protection, and fail-closed write handling.
- Historical stop and risk snapshots may be zero when the broker history does not supply them. Zero means unknown, not zero live exposure. Live risk must still come from current broker positions and protective stops.
- `CampaignHistoryReconciler.mqh` replays broker-selected deal history for the configured EA magic, records actual broker deal volume/price and costs, classifies IN/OUT/INOUT/OUT_BY, and rejects incomplete or conflicting deal identities.
- History replay deliberately leaves campaign ID and signal key empty when no trusted attribution source exists. It does not promote broker comments into authoritative campaign identity. Such records remain unresolved and must block campaign additions.
- The journal and replay component are not yet wired into EA startup or `OnTradeTransaction`. No campaign can be considered recovered solely because these files exist.
- Python reference tests cover idempotent deal identity, partial fills, netting volume, reversals, unresolved attribution, and missing historical stop snapshots. The latest commits returned no associated pull-request workflow runs. MQL5 compilation and Strategy Tester validation remain outstanding.

## EA integration progress (2026-11-04)

- The EA now includes and initializes `CampaignJournal.mqh` after the existing open-setup registry has reconciled.
- Journal initialization failure blocks new entries while leaving existing-position management active.
- On startup, every currently open position owned by this EA must have an attributed `IN` or `INOUT` deal in the journal. Legacy open positions without that evidence remain managed but block new entries.
- The `OnTradeTransaction` deal-add path now reads broker deal properties, resolves the stable position identifier through the existing restart registry, and appends the actual fill/exit deal before final-exit handling can remove that setup mapping.
- Missing setup attribution, an invalid deal record, or a failed journal append latches the existing recovery entry gate closed.
- The journal records zero for historical stop/risk-at-fill snapshots when those values are unavailable. Current account risk continues to be calculated from broker positions and protective stops, not journal snapshots.
- Netting reversal `INOUT` deals can satisfy the attributed-position recovery check when they carry a trusted campaign ID.

This integration is still preliminary. It does not yet replay broker history into the journal at startup, reconstruct campaign state from all prior deals, persist an explicit campaign-intent event before order submission, or manage multiple concurrent legs. The EA remains single-position-oriented and hedging accounts remain rejected. A source review and MQL5 compile are still required before treating this integration as validated.

### Multi-instance isolation and delayed history

- Journal identity now includes account login, broker server hash, EA magic, and chart symbol. The file path and header are symbol-scoped, preventing two symbol instances with the same magic from writing into one journal.
- The journal schema was advanced to version 2 for the symbol-bound header. The earlier development schema is not silently accepted.
- If MT5 announces a deal but the history record is not yet readable, the EA latches the entry gate closed. It does not create a zero-value fill. Automatic retry/backfill of that missed callback is still outstanding and must be implemented before this can be considered restart-complete.

### Startup broker-history replay integration

- Startup now selects broker history from the beginning of available history through the current server time, scoped to this EA magic and chart symbol.
- For a deal whose stable position identifier still exists in the verified restart registry, replay attaches that exact persisted setup ID as campaign attribution.
- Closed historical deals whose setup mapping no longer exists are retained as broker-confirmed but unattributed records. They are not assigned a guessed campaign.
- Replay is idempotent by deal ticket. Existing records are checked against broker identity and fill economics; current open positions still require an attributed opening deal before the entry gate can be enabled.
- If history selection fails, startup remains blocked. If history is available but does not contain the opening deal for an open position, that position remains managed while new entries stay blocked.

This closes the basic delayed-callback recovery path after restart. It is not a complete event-sourced campaign state machine: attribution amendments to already-written unattributed rows, durable pre-order intent, and automatic same-session retry of a temporarily unavailable deal remain open work.

### Deal stop snapshot semantics

The persisted field is named `dealStopSnapshot`, not `stopAtFill`. MT5's `DEAL_SL` property is contextual: entry and reversal deals carry the stop from the opening order, while exit deals carry the position stop as it stood at closure. It must not be interpreted as the original stop for every deal type. Current open-risk is still recalculated from live broker positions and their current protective stops. See the [MQL5 Deal Properties reference](https://www.mql5.com/en/docs/constants/tradingconstants/dealproperties).


### Append-only attribution amendments

A broker deal row is immutable after append. If startup replay initially records a deal without a campaign because its exact open-position setup mapping is temporarily unavailable, a later replay may add a separate `ATTR` journal event.

The amendment repeats the original deal identity and economics, references the same deal ticket, and supplies the campaign/setup ID and signal key. It is accepted only when the original deal row exists, every immutable broker field matches, and no conflicting campaign or signal attribution exists. Repeated identical amendments are idempotent.

Journal replay applies the amendment as an overlay to the in-memory deal record. The original `DEAL` row is never rewritten. Orphan amendments, altered economics, and conflicting attribution invalidate journal recovery and keep new entries blocked.

The history reconciler attempts this upgrade only when `CRestartRecovery` returns the exact persisted setup mapping for the same broker position identifier and symbol. A comment, symbol match alone, or guessed campaign is not sufficient.

Reference acceptance tests cover successful upgrade, repeated idempotent amendment, conflicting campaign IDs, and invalid-journal rejection. These are Python reference tests, not MQL5 compilation or broker-runtime proof.


### Same-session deal-history retry

A `DEAL_ADD` callback whose history record is not yet readable is now queued by exact deal ticket. The queue is deduplicated, bounded to 128 tickets, and never silently evicts an unresolved ticket. Capacity or allocation failure keeps the recovery entry gate closed.

The EA retries at most four queued tickets per tick or one-second timer event. The timer is active even when the dashboard is disabled, so recovery does not depend on dashboard rendering or a fresh market tick. A queued deal is removed only after its broker history is readable, the exact persisted position-to-setup mapping is available, and the deal is durably appended or reconciled in the campaign journal.

The retry lock is separate from the broader restart-recovery latch. It clears only after the queue drains and every currently open position owned by this EA on the chart symbol has an attributed opening deal. Unknown mappings, journal write failures, and unresolved history keep new entries blocked. Existing position management remains active.

The retry queue is in-memory by design. If the terminal restarts before a retry completes, startup broker-history replay remains the recovery path. This queue is not a substitute for the still-pending durable pre-order intent journal.


Delayed deal persistence first checks the exact open-setup registry mapping. If that mapping has already been removed after a completed close, the retry may reuse an attribution already persisted for another deal with the same broker `POSITION_IDENTIFIER`. This fallback is position-identity scoped and reads only an existing durable campaign assignment. It never derives a campaign from symbol, direction, comment, or timing.


## Durable pre-order campaign intent

The EA now writes a separate account/server/magic/symbol-scoped intent ledger before calling the market execution engine. Each `PREPARE` record contains a unique intent/campaign ID, a signal key derived from symbol, direction, flip sequence and the active M15 setup-bar timestamp, symbol, direction, requested volume, intended protective stop, proposed risk budget in account currency, and creation time. The ledger is append-only and checksummed. If the write fails, the market order is not sent.

After the execution engine receives a broker order result, the exact `ResultOrder()` ticket is appended as a `BIND` event. The engine exposes both the order ticket and final server retcode to its caller. The setup registry uses the campaign ID from the pre-order intent rather than generating a new post-fill identity. Partial fills therefore resolve to the same campaign through their broker order ticket.

The deal callback and startup history replay now resolve attribution in this order:

1. Exact broker `DEAL_ORDER` to durable intent order-ticket binding. This preserves the original signal key as well as the campaign ID.
2. Exact persisted open-position mapping by broker `POSITION_IDENTIFIER`, used for legacy positions without a matching intent.
3. Existing durable campaign attribution for the same broker position identifier.

No mapping is inferred from symbol, direction, order comment, or approximate time.

A definitive rejected send is recorded as `REJECT`. A timeout, connection failure, missing server retcode, or other ambiguous outcome leaves the intent in `PREPARED`. Any unresolved prepared intent blocks subsequent entries, including after restart. This deliberately favours a manual reconciliation requirement over risking a duplicate order after a crash or uncertain broker response. A prepared intent is not automatically discarded merely because no fill is visible at startup.

A bound intent records broker order identity, not proof that every requested unit filled. Actual filled volume and economics continue to come only from broker deal history. The ledger does not change the 2% aggregate account risk ceiling, does not enable pyramiding, and does not alter the `ANALYSIS_ONLY` default.

Python acceptance tests model prepare-before-submit, failed persistence, broker-ticket binding, idempotent binding, terminal rejection, and restart blocking for unresolved intents. They are reference tests only. MetaEditor compilation, MT5 Strategy Tester validation, partial-fill broker testing, and crash-injection tests remain outstanding.


### Crash window between broker acceptance and intent binding

There is an unavoidable interval between the broker accepting a market request and the EA durably appending the returned order ticket. If the terminal stops in that interval, the intent remains `PREPARED`.

On startup, after selecting broker history, the reconciler checks whether there is exactly one prepared intent. It searches historical orders for a unique match on account-scoped EA magic, symbol, direction, setup time, initial requested volume, and protective stop. Only one exact match is bound to the intent. Zero matches leave the intent unresolved; multiple matches are treated as ambiguous and fail recovery. No comment-only or symbol-only matching is permitted.

The unresolved-intent gate is evaluated after this broker-history reconciliation attempt, so a crash after broker acceptance but before the local bind can recover automatically when the broker's historical order is available. A crash before order submission leaves no matching order and requires manual resolution. The reference tests cover unique match, ambiguous multiple matches, and stop mismatch rejection.


## Broker-history recovery for the order-binding crash window

Each prepared intent now produces a short broker comment token from its persisted intent ID. The token is included in the market-order comment (with an optional full-margin suffix) and is retained in the intent journal by deterministic derivation. It is a lookup key, not proof of identity.

On startup, timer and tick, the EA scans broker order history for each unresolved prepared intent. It binds an order only when exactly one order carries that token, the token is owned by exactly one journal intent, and broker metadata agrees on account-scoped magic, symbol, direction, requested initial volume, protective stop and a bounded creation-time window. A fill or linked broker deal must exist before a candidate is bound. Definitive canceled, expired or rejected orders with no linked fill can be closed as rejected. Duplicate token matches, metadata mismatches, missing tokens, missing history and uncertain states remain unresolved and block new entries.

The history scan is not capped to the most recent day. An intent left unresolved during a long terminal outage can still be checked against the broker history from its creation time. The scan never submits another order. If a broker strips or rewrites comments, recovery deliberately stops for manual reconciliation rather than guessing from symbol, side, volume or timestamp alone.

Reference tests cover unique recovery, duplicate candidates, wrong side, wrong magic, stale timestamps, missing broker token and unfilled orders. These are Python reference tests and static source checks, not a broker integration test. The exact comment-preservation behaviour and order-history semantics still require validation on each target broker.


### Execution-result classification

A nonzero trade retcode is not automatically treated as a rejection. Only an explicit allowlist of negative server outcomes can close a prepared intent as rejected, and only when no broker order ticket was returned. A returned order ticket is bound to the intent even when the terminal cannot yet confirm the resulting position. In that case, the EA locks new entries until the position and campaign state can be reconciled. Success retcodes, partial-success retcodes, timeouts, connection loss, zero and unknown retcodes never become a false rejection.
