# 09. Database Schema

Migration: [`intel/migrations/0001_init.sql`](../../intel/migrations/0001_init.sql). Target: PostgreSQL 15+ with TimescaleDB hypertables for high-volume series. The research core currently runs on the in-memory `EventStore` with a JSONL dataset format; the schema is the Phase 3 persistence target and mirrors the same records.

## Rules baked into the schema

1. **Two clocks everywhere.** `ts` and `seen_ts` on every event table; point-in-time indexes on `(chain, token, seen_ts)`.
2. **Natural keys dedupe.** `(chain, tx_hash, log_index)` for swaps and liquidity events. Re-ingestion is an upsert.
3. **Append, don't edit.** Corrections are new rows with a later `seen_ts`. Only `provider_health` is updated in place.
4. **NULL means unknown.** `feature_values` enforces `status <> 'OK' OR value IS NOT NULL`, and `status` is never null.
5. **Outcomes quarantined.** `news_reactions`, journal outcomes and backtest metrics live in tables the feature code never reads.

## Tables

| Group | Table | Key | Notes |
|---|---|---|---|
| Reference | `tokens` | (chain, address) | symbol index for collision checks |
| | `pools` | (chain, pool) | `amm_model` drives slippage model choice |
| | `address_book` | (chain, address) | exchanges, bridges, routers, burn, LP lockers; excluded as cluster funders and from holder concentration |
| Market | `swaps` (hypertable) | (chain, tx_hash, log_index, ts) | `source` records which ingestor wrote it |
| | `liquidity_events` | (chain, tx_hash, log_index) | adds and removals with provider wallet |
| | `pool_snapshots` (hypertable) | (chain, pool, source, ts) | multi-source for cross-checks |
| On-chain | `holder_snapshots` | (chain, token, source, ts) | stores which addresses were excluded |
| | `funding_transfers` | (chain, tx_hash, src, dst) | indexed by src and dst for graph building |
| Information | `news_events` | event_id | GIN index on token keys |
| | `news_reactions` | (event_id, token, horizon) | measured after the fact |
| | `social_posts` (hypertable) | (platform, post_id) | |
| Derived | `feature_values` (hypertable) | (token, feature, as_of, feature_version) | versioned features coexist |
| | `assessments` | (token, as_of, config_hash) | full JSON payload for audit and the Token Autopsy view |
| | `manipulation_flags` | (token, as_of, kind) | evidence, wallets, txs, methodology, alternative |
| | `signals` | signal_id | `mode` = backtest / paper / live |
| | `alerts` | alert_id | text plus evidence JSON |
| Audit | `journal` | seq, unique hash | hash chain; rules block UPDATE and DELETE |
| | `backtest_runs` | run_id | dataset version, config hash, code version, split |
| Ops | `provider_health` | provider | last success, last error, rate-limited flag |

## Retention and versioning

* Raw swaps, liquidity, funding: kept indefinitely (they are the dataset). Timescale compression after 7 days.
* Social posts: retention subject to each platform's terms; store derived aggregates when raw retention is not permitted.
* Datasets are versioned by `(ingestor version, coverage ranges, collection end)`; `backtest_runs.dataset_version` pins which one a result came from.
* Schema changes go through numbered migrations with `schema_version` rows. No manual DDL in production.
