# 17. Three-Clock Point-in-Time Contract

Status: implementation added; CI verification pending.
Scope: deterministic event/feature admissibility and snapshot construction.
This is a research-data contract, not a production collector or trading signal.

## Why this change exists

The existing event store filters records by `seen_ts`. That prevents events received after a decision from leaking backward, but it does not prove that parsing, normalization and feature computation had finished by the decision. The evaluation protocol therefore distinguishes:

- `event_ts`: when the source says the underlying event occurred;
- `first_seen_ts`: when our collector first received it;
- `feature_ready_ts`: when the normalized event or derived feature became usable;
- `decision_ts`: when the strategy was allowed to make the decision.

The required event chronology is:

```
event_ts <= first_seen_ts <= feature_ready_ts <= decision_ts
```

A feature must also be ready no earlier than every source event used to compute it. A record arriving before a decision but becoming usable afterward is excluded from that decision.

## Chain ordering

Timestamps alone do not uniquely order Solana activity. Where chain lineage is available, the snapshot builder orders by:

```
(chain, slot, transaction_index, instruction_index, event_index, event_id)
```

All four numeric lineage fields must be present together and non-negative. Duplicate lineage tuples within one chain are rejected. If lineage is unavailable, the deterministic fallback is `(chain, event_ts, event_id)`; this fallback does not claim to reconstruct within-slot execution order.

## Fail-closed validation

`intel/autopsyx/research/point_in_time.py` introduces:

- immutable event and feature envelopes;
- explicit validation issues with stable reason codes;
- source-event readiness checks;
- duplicate identity and chain-lineage checks;
- deterministic sorting and SHA-256 snapshot fingerprints;
- a builder that raises `ValueError` rather than silently dropping invalid or late records.

The builder does not mutate the existing EventStore or change production scan behaviour. Integration is a separate step after this contract is reviewed and tested.

## Regression coverage

`intel/tests/test_point_in_time_contract.py` covers valid chronology, late observations, late feature readiness, impossible clock order, missing payload hashes, incomplete/duplicate chain lineage, unknown feature sources, feature-before-source readiness, deterministic ordering, stable digests and fail-closed construction.

## Acceptance boundary

Passing these tests proves only that the contract implementation behaves as specified on deterministic fixtures. It does not prove provider completeness, historical coverage, profitable signals, realistic fills or live execution quality.

Next integration step: adapt canonical provider records into these envelopes while preserving raw source identity and receipt timestamps; then add a replay test proving a later-arriving or later-ready event cannot alter an earlier decision snapshot.
