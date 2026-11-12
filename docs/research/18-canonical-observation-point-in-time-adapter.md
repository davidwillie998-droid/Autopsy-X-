# 18. Canonical Observation Adapter for the Three-Clock Contract

## Scope

This increment connects the Phase 3A canonical `Observation` record to the
provider-neutral point-in-time envelope introduced in document 17. It is an
adapter boundary, not a replacement for `EventStore` or a production signal.

## Mapping

| Point-in-time field | Canonical observation source |
|---|---|
| `event_ts` | `source_ts`, only when explicitly observed |
| `first_seen_ts` | `ingestion_ts` |
| `feature_ready_ts` | Required explicit adapter argument |
| `payload_hash` | `raw_id`, required provenance identifier |
| `chain` | `chain` |
| `event_id` | SHA-256 of canonical identity, provider and raw provenance identifier |

The adapter rejects records without an observed provider event timestamp.
`observation_ts` is deliberately not a fallback: the canonical schema defines
it as the best-known time, which may be a response time rather than the actual
event or publication time. Such records remain in the canonical observation
store but are not admitted to strict point-in-time event-time evaluation until
the source timestamp is established.

The adapter does not infer Solana transaction order from `slot`, `signature`,
or partial instruction metadata. The canonical observation schema does not
currently guarantee slot, transaction index, instruction index and event index
as a complete tuple. Inventing missing indices would create false ordering.

## Fail-closed rules

- Missing `raw_id` is rejected.
- Missing or non-observed `source_ts` is rejected. Local observation and
  ingestion timestamps are never substituted for event/publication time.
- `feature_ready_ts` must be supplied by the caller. It is never copied from
  `ingestion_ts` by default.
- The downstream snapshot validator rejects events whose feature-ready time
  is later than the decision timestamp.

## Tests added

- Three timestamps and raw provenance are preserved.
- Missing provider event time is rejected rather than silently substituted.
- Event identity is deterministic and changes when raw provenance changes.
- Missing raw provenance is rejected.
- A snapshot cannot admit an event that was not feature-ready by decision time.

## Remaining integration boundary

This adapter covers Phase 3A `Observation` records only. Other canonical
event types (swaps, liquidity events, bars, snapshots, holder records, news and
social records) still need explicit adapters. Their event identities and
feature-ready timestamps must be mapped from source evidence, not guessed.
No provider coverage, strategy performance or executable edge is established
by these synthetic contract tests.
