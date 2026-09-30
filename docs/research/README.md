# AUTOPSY X Intelligence Engine: Research Deliverables

Phase 1 output. These documents define what the engine measures, how, from which data, and how each claim gets tested before any capital touches it. Code lives in [`intel/`](../../intel); every threshold named here is a key in [`intel/config/default.toml`](../../intel/config/default.toml).

| # | Document | Answers |
|---|---|---|
| 01 | [Architecture](01-architecture.md) | Stages, contracts, data flow, the point-in-time rule |
| 02 | [Data-source matrix](02-data-source-matrix.md) | Which provider feeds which stage, and what each one cannot do |
| 03 | [Feature dictionary](03-feature-dictionary.md) | Definition, source, formula, lookback, failure mode, test for every feature |
| 04 | [Signal specification](04-signal-specification.md) | Move classes, Move Quality, regimes, exhaustion, entry, exit, confidence |
| 05 | [Manipulation methodology](05-manipulation-methodology.md) | Each detector, its evidence, and its benign explanation |
| 06 | [News-event taxonomy](06-news-event-taxonomy.md) | Event types, source tiers, confirmation, news-to-move timing |
| 07 | [Narrative taxonomy](07-narrative-taxonomy.md) | Membership, momentum, phases, leader/follower |
| 08 | [Backtesting methodology](08-backtesting-methodology.md) | Leakage controls, fills, metrics, event studies, model validation |
| 09 | [Database schema](09-database-schema.md) | Tables, keys, the two-clock rule, retention |
| 10 | [API abstraction](10-api-abstraction.md) | Provider protocols, transport, adapter contract |
| 11 | [Risk specification](11-risk-specification.md) | Sizing, exposure limits, refusal rules |
| 12 | [Testing strategy](12-testing-strategy.md) | Unit, replay, leakage, integration, paper-trading gates |
| 13 | [Known limitations](13-known-limitations.md) | What this system cannot see or cannot yet claim |
| 14 | [Research hypotheses](14-research-hypotheses.md) | H1 to H10 with test designs and kill criteria |

## Status

| Phase | State |
|---|---|
| 1 Research and architecture | This document set |
| 2 Data-source audit | Matrix drafted; no vendor verified live yet (build container had no outbound access to vendor APIs) |
| 3 Historical dataset | Schema and JSONL replay format defined; no historical data collected |
| 4 to 10 Engines | Reference implementations with tests on synthetic scenarios |
| 11 Backtesting | Point-in-time engine implemented; no historical results exist |
| 12 to 14 Paper, live, execution | Not started. Execution stays disconnected until 11 and 12 pass their gates |

Synthetic scenarios prove the code does what the spec says. They prove nothing about markets.
