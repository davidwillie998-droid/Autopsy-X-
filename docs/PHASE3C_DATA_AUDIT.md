# Phase 3C Data Audit

Contract hash `a317239dfc492486657b55f8980c463559de37edef95af21b5247420a4aee527`. Included archives: gt-sol-20260930a, gt-sol-20260930b, gt-sol-20260930c, p3a-sol-20261001d2, p3c-sol-20261004e, p3c-sol-20261004f.

## Contamination (token overlap across archives)

Contamination-free: **False**.

| Archive | Tokens |
|---|---|
| gt-sol-20260930a | 12 |
| gt-sol-20260930b | 8 |
| gt-sol-20260930c | 5 |
| p3a-sol-20261001d2 | 5 |
| p3c-sol-20261004e | 22 |
| p3c-sol-20261004f | 14 |


Overlaps found (contamination):

* ['p3c-sol-20261004e', 'p3c-sol-20261004f']: ['4mpyrARsWyLWncvKtHf9aoddnfv24QmVBtUFU4ic5wUp', '7VertkgF9KLhxxJXHX6uaWuoYZTP9LdGj2bWmVXVpump']

Resolution: deterministic deduplication by acquisition start time (`run.json["started_ms"]`) -- a token present in more than one archive contributes rows from only the earliest-acquired archive; the rest are dropped before any statistic is computed.


## Per-archive observation coverage

### gt-sol-20260930a

* Observations: 98, tokens with any observation: 12
* Provenance: source=normalize_stdout.json (Phase 2 runner normalization), verified=True, scope=phase2_records only (archive predates Phase 3A runner sealing)
* Duplicates/staleness: {"phase2_duplicate_swaps": 26176, "phase2_coverage_gap_count": 3, "phase3a_duplicate_observations": 156, "phase3a_observation_states": {"creator_state|ERROR": 16, "creator_state|OBSERVED": 26, "holder_state|ERROR": 16, "holder_state|NOT_OBSERVED": 3, "holder_state|OBSERVED": 23, "liquidity_event|OBSERVED": 100}}

| kind|state | count |
|---|---|
| creator_state|ERROR | 16 |
| creator_state|OBSERVED | 26 |
| holder_state|ERROR | 16 |
| holder_state|NOT_OBSERVED | 3 |
| holder_state|OBSERVED | 23 |
| liquidity_event|OBSERVED | 14 |

### gt-sol-20260930b

* Observations: 16, tokens with any observation: 8
* Provenance: source=normalize_stdout.json (Phase 2 runner normalization), verified=True, scope=phase2_records only (archive predates Phase 3A runner sealing)
* Duplicates/staleness: {"phase2_duplicate_swaps": 0, "phase2_coverage_gap_count": 0, "phase3a_duplicate_observations": 3, "phase3a_observation_states": {"creator_state|OBSERVED": 4, "holder_state|NOT_OBSERVED": 3, "holder_state|OBSERVED": 1, "liquidity_event|OBSERVED": 97}}

| kind|state | count |
|---|---|
| creator_state|OBSERVED | 4 |
| holder_state|NOT_OBSERVED | 3 |
| holder_state|OBSERVED | 1 |
| liquidity_event|OBSERVED | 8 |

### gt-sol-20260930c

* Observations: 47, tokens with any observation: 5
* Provenance: source=normalize_stdout.json (Phase 2 runner normalization), verified=True, scope=phase2_records only (archive predates Phase 3A runner sealing)
* Duplicates/staleness: {"phase2_duplicate_swaps": 12209, "phase2_coverage_gap_count": 0, "phase3a_duplicate_observations": 81, "phase3a_observation_states": {"creator_state|NOT_OBSERVED": 4, "creator_state|OBSERVED": 17, "holder_state|NOT_OBSERVED": 5, "holder_state|OBSERVED": 16, "liquidity_event|OBSERVED": 99}}

| kind|state | count |
|---|---|
| creator_state|NOT_OBSERVED | 4 |
| creator_state|OBSERVED | 17 |
| holder_state|NOT_OBSERVED | 5 |
| holder_state|OBSERVED | 16 |
| liquidity_event|OBSERVED | 5 |

### p3a-sol-20261001d2

* Observations: 572, tokens with any observation: 5
* Provenance: source=run.json provenance (sealed on runner), verified=True, scope=phase2_records and phase3a_observations
* Duplicates/staleness: {"phase2_duplicate_swaps": 8269, "phase2_coverage_gap_count": 0, "phase3a_duplicate_observations": 354, "phase3a_observation_states": {"creator_state|OBSERVED": 19, "funding_transfer|ERROR": 20, "funding_transfer|NOT_OBSERVED": 76, "funding_transfer|OBSERVED": 266, "holder_state|NOT_OBSERVED": 4, "holder_state|OBSERVED": 15, "liquidity_event|ERROR": 26, "liquidity_event|NOT_OBSERVED": 81, "liquidity_event|OBSERVED": 142, "news|ERROR": 6, "news|NOT_OBSERVED": 2, "social|ERROR": 10}}

| kind|state | count |
|---|---|
| creator_state|OBSERVED | 19 |
| funding_transfer|ERROR | 20 |
| funding_transfer|NOT_OBSERVED | 76 |
| funding_transfer|OBSERVED | 266 |
| holder_state|NOT_OBSERVED | 4 |
| holder_state|OBSERVED | 15 |
| liquidity_event|ERROR | 26 |
| liquidity_event|NOT_OBSERVED | 81 |
| liquidity_event|OBSERVED | 47 |
| news|ERROR | 6 |
| news|NOT_OBSERVED | 2 |
| social|ERROR | 10 |

### p3c-sol-20261004e

* Observations: 2952, tokens with any observation: 22
* Provenance: source=run.json provenance (sealed on runner), verified=True, scope=phase2_records and phase3a_observations
* Duplicates/staleness: {"phase2_duplicate_swaps": 0, "phase2_coverage_gap_count": 0, "phase3a_duplicate_observations": 1878, "phase3a_observation_states": {"creator_state|OBSERVED": 22, "funding_transfer|ERROR": 8, "funding_transfer|NOT_OBSERVED": 278, "funding_transfer|OBSERVED": 1794, "holder_state|NOT_OBSERVED": 11, "holder_state|OBSERVED": 11, "liquidity_event|ERROR": 76, "liquidity_event|NOT_OBSERVED": 395, "liquidity_event|OBSERVED": 291, "news|ERROR": 28, "news|NOT_OBSERVED": 16, "social|ERROR": 44}}

| kind|state | count |
|---|---|
| creator_state|OBSERVED | 22 |
| funding_transfer|ERROR | 9 |
| funding_transfer|NOT_OBSERVED | 289 |
| funding_transfer|OBSERVED | 1853 |
| holder_state|NOT_OBSERVED | 11 |
| holder_state|OBSERVED | 11 |
| liquidity_event|ERROR | 76 |
| liquidity_event|NOT_OBSERVED | 395 |
| liquidity_event|OBSERVED | 198 |
| news|ERROR | 28 |
| news|NOT_OBSERVED | 16 |
| social|ERROR | 44 |

### p3c-sol-20261004f

* Observations: 580, tokens with any observation: 14
* Provenance: source=run.json provenance (sealed on runner), verified=True, scope=phase2_records and phase3a_observations
* Duplicates/staleness: {"phase2_duplicate_swaps": 1747, "phase2_coverage_gap_count": 1, "phase3a_duplicate_observations": 287, "phase3a_observation_states": {"creator_state|OBSERVED": 18, "funding_transfer|ERROR": 3, "funding_transfer|NOT_OBSERVED": 66, "funding_transfer|OBSERVED": 278, "holder_state|ERROR": 1, "holder_state|NOT_OBSERVED": 2, "holder_state|OBSERVED": 15, "liquidity_event|ERROR": 16, "liquidity_event|NOT_OBSERVED": 69, "liquidity_event|OBSERVED": 133, "news|ERROR": 17, "news|NOT_OBSERVED": 11, "social|ERROR": 28}}

| kind|state | count |
|---|---|
| creator_state|OBSERVED | 18 |
| funding_transfer|ERROR | 3 |
| funding_transfer|NOT_OBSERVED | 66 |
| funding_transfer|OBSERVED | 278 |
| holder_state|ERROR | 1 |
| holder_state|NOT_OBSERVED | 2 |
| holder_state|OBSERVED | 15 |
| liquidity_event|ERROR | 16 |
| liquidity_event|NOT_OBSERVED | 69 |
| liquidity_event|OBSERVED | 56 |
| news|ERROR | 17 |
| news|NOT_OBSERVED | 11 |
| social|ERROR | 28 |

## New archives excluded (if any)

None: every acquired Phase 3C archive passed provenance and completion.
