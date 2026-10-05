# Phase 3C.1 Acquisition Protocol

## Purpose

Phase 3C.1 repairs the Phase 3C acquisition scheduling failure without changing the frozen statistical contract.

The Phase 3C evidence showed that Archive E completed provenance verification but consumed the available duration budget during enrichment, leaving no live replay window. Archive F demonstrated that a reduced RPC budget could produce a genuine replay window. Phase 3C.1 addresses the scheduling failure directly rather than treating a reduced universe as the permanent solution.

## Frozen research contract

- Eligible hypotheses: H1, H3, H4, H8, H9, H10.
- Independent statistical unit: distinct token.
- `MIN_SAMPLE = 85` remains unchanged.
- Existing contamination, provenance, determinism, replication, adversarial, and OOS gates remain unchanged.
- No production EA or MQL5 integration is permitted.

## Protected replay scheduler

The total acquisition duration is partitioned into:

1. discovery and universe freezing;
2. bounded backfill;
3. bounded enrichment;
4. a protected replay allocation;
5. archive sealing and verification.

For the Phase 3C.1 acquisition request:

- total duration: 3,000 seconds;
- protected replay reserve: 1,800 seconds;
- enrichment start guard: 180 seconds;
- replay cycle: 60 seconds;
- RPC page limit: 100;
- RPC max pages: 1;
- RPC max transactions: 8.

The scheduler computes the replay deadline before enrichment starts. Pre-replay work cannot intentionally consume the reserved replay allocation.

## Completion rule

An acquisition is `COMPLETE` only when the observed replay duration is at least the protected replay reserve. Otherwise the archive is marked `INCOMPLETE_REPLAY` and cannot be treated as a successful evidence archive.

## Enrichment rule

Enrichment is performed token-by-token. The scheduler refuses to begin another token's enrichment once the conservative guard interval is reached. There is no post-replay enrichment stage in Phase 3C.1, because post-replay enrichment would recreate the exact resource contention that caused Archive E to fail as a replay archive.

## Evidence interpretation

The acquisition repair itself is an engineering result, not evidence for any market hypothesis. A successful Phase 3C.1 archive only increases the amount of admissible evidence. Statistical conclusions remain governed by the frozen Phase 3C protocol.

## Promotion boundary

No result from Phase 3C.1 may be promoted directly into an EA, MT5 execution, or production trading rule. The sequence remains acquisition → audit → frozen statistics → replication → adversarial validation → OOS eligibility → production review.
