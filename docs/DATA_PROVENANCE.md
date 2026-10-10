# Data Provenance

Every normalized value in the research store can be traced to the bytes a vendor returned, to the request that fetched them, and to the time the system first held them.

## Chain of custody

```
vendor endpoint
   │  HttpClient.get_raw: exact body bytes, request_ts, response_ts, attempts
   ▼
raw archive  (intel/datasets/phase2/runs/<run_id>/)
   manifest.jsonl          one line per exchange, failures included
   raw/<sha256>.json.gz    body, content-addressed; gzip mtime fixed at 0
   selection.json          universe selection: seed, strata, candidates, picks, exclusions
   run.json                start/end, plan, code version (GITHUB_SHA), runner
   │  data/normalize.py: pure adapters, deterministic
   ▼
normalized records  (every record: source, raw_id, ts, seen_ts)
   + normalization_report.json  (every drop, derivation, flag, with raw_id)
   │  providers/store.py: EventStore.view(as_of) exposes seen_ts <= as_of only
   ▼
research core (unchanged engines)
   │  replay.py
   ▼
journal.jsonl (hash-chained) + summary.json (records_sha256)
```

## Identifiers

| Field | Meaning |
|---|---|
| `raw_id` | sha256 of the response body. `RawStore.body()` re-hashes on read and refuses a body that fails its own hash |
| `source` | adapter name (`geckoterminal`, `dexscreener`) |
| `ts` (event_time) | when the event happened, in the provider's own semantics (below) |
| `seen_ts` (available_time) | `response_ts` of the first response that contained the record, from the acquisition machine's clock |
| `dataset_sha256` | sha256 over every normalized record in order; recorded in the normalization report and in the replay `dataset_id` |
| `configuration_hash` | `Config.fingerprint()`; every replay record carries it |
| `code_version` | git commit of the acquisition run (`GITHUB_SHA`) and of the replay working tree |

## Timestamp semantics per record

| Record | `ts` | `seen_ts` | Notes |
|---|---|---|---|
| Swap (GeckoTerminal trade) | `block_timestamp`, 1 s resolution | response time of the poll that first returned it | Later polls return the same trade again; the earliest `seen_ts` wins (quality gate dedupe) |
| ProviderBar (GeckoTerminal OHLCV) | bar open (unix seconds × 1000) | response time | Bars not closed `lag_ms` (60 s) before the response are dropped and reported (`FORMING_BAR_DROPPED`). Revised bars are kept as new versions; the view shows the latest version seen by `as_of` |
| PoolSnapshot | response time | response time | Neither vendor gives an event time for pool state; the snapshot means "as reported at this moment" |
| HolderSnapshot | `holders.last_updated` | response time | The vendor's own update time is kept as event time |
| PoolInfo | `pool_created_at` (as `created_ts`) | response time | |
| TokenMeta | `launch_ts` = earliest pool creation seen | response time | Pool creation, not mint creation |
| Coverage | claimed interval `[start_ts, end_ts)` | response time | See below |

## Coverage claims

A Coverage record states that a stream was complete over an interval, as of a response.

* **trades.** A trades response with fewer than 300 rows returned every trade of the last 24 h, so coverage is `[response − 24 h, response − lag)`. A full page (300 rows) may have truncated older trades: coverage starts at the oldest returned trade and the response is flagged `PAGE_FULL`.
* **bars.** An OHLCV response covers `[oldest returned bar, response − lag)`, floored to the minute. Inside covered intervals a missing minute means the provider recorded no trades (GeckoTerminal omits empty minutes). Outside them a missing minute is unknown and the bar is marked incomplete.

Engines read order flow (buyers, sellers, buy/sell split, trade count) only where trade coverage spans the whole bar or window. Elsewhere those fields are MISSING or INSUFFICIENT_HISTORY. Unobserved minutes are never counted as zero buyers.

## Explicit, deterministic repairs and derivations

| Code | What happens | Why |
|---|---|---|
| `DERIVED_FIELD` | `total_supply = fdv_usd / base_token_price_usd` | GeckoTerminal gives FDV and price but not supply; the division is exact by definition of FDV |
| `FORMING_BAR_DROPPED` | unclosed bars removed | a partial candle must not stand in for a closed one |
| `DUPLICATE_OBSERVATION` | counted; earliest `seen_ts` kept downstream | poll overlap is expected; the first sighting is the availability time |
| everything else in `data/validate.Code` | the record is dropped (or the response skipped) and reported with its `raw_id` | invalid values are never corrected |

A provider-reported zero is kept as zero (e.g. `reserve_in_usd = "0.0"` for a completed bonding curve). A null, empty, non-numeric or non-finite value becomes `None`, never 0.

## What is not provenance-complete

* Adapter fixtures under `intel/tests/fixtures/phase2/` were captured through a fetch relay during schema probing (the build container cannot reach vendor hosts) and trimmed by removing items. They test parsers; they are not research data.
* `TokenMeta` built from token-info responses takes `launch_ts` and `total_supply` from the acquisition context (values derived from an earlier pools response), not from the token-info body itself. The earlier response's `raw_id` is recoverable from the manifest context but is not stored on the record.
