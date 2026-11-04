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
