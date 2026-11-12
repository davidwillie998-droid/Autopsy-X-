# 18. Canonical Observation Adapter for the Three-Clock Contract

## Scope

This increment connects the Phase 3A canonical `Observation` record to the
provider-neutral point-in-time envelope introduced in document 17. It is an
adapter boundary, not a replacement for `EventStore` or a production signal.

## Mapping

| Point-in-time field | Canonical observation source |
|---|---|
| `event_ts` | `source_ts` when explicitly observed, otherwise `observation_ts` |
| `first_seen_ts` | `ingestion_ts` |
| `feature_ready_ts` | Required explicit adapter argument |
| `payload_hash` | `raw_id`, required |
| `chain` | `chain` |
| `event_id` | SHA-256 of canonical identity, provider and raw payload identity |

The adapter does not infer Solana transaction order from `slot`, `signature`,
or partial instruction metadata. The canonical observation schema does not
currently guarantee slot, transaction index, instruction index and event index
as a complete tuple. Inventing missing indices would create false ordering.

## Fail-closed rules

- Missing `raw_id` is rejected.
- `feature_ready_ts` must be supplied by the caller. It is never copied from
  `ingestion_ts` by default.
- The downstream snapshot validator rejects events whose feature-ready time
  is later than the decision timestamp.
- A provider timestamp is used only when its availability state says it was
  actually observed; otherwise the best-known `observation_ts` is retained.

## Tests added

- Three timestamps and raw provenance are preserved.
- Missing provider event time falls back to the canonical observation time.
- Event identity is deterministic and changes when raw provenance changes.
- Missing payload hash is rejected.
- A snapshot cannot admit an event that was not feature-ready by decision time.

## Remaining integration boundary

This first adapter covers Phase 3A `Observation` records only. Other canonical
event types (swaps, liquidity events, bars, snapshots, holder records, news and
social records) still need explicit adapters. Their event identities and
feature-ready timestamps must be mapped from source evidence, not guessed.
No provider coverage, strategy performance or executable edge is established
by these synthetic contract tests.
