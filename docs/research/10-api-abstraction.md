# 10. API Abstraction Design

## Layers

```
vendor API ──► adapter (one per vendor)  ──► canonical records (core/models.py)
                  │  uses                        │
                  ▼                              ▼
             HttpClient                     EventStore / database
   (TokenBucket, retries, CircuitBreaker)        │
                                                 ▼
                                        PointInTimeView ──► engines
```

No engine imports an adapter. Engines see canonical records only, so replacing DexScreener with Birdeye, or Helius with a self-hosted RPC, changes one file.

## Provider protocols (`providers/base.py`)

| Protocol | Methods |
|---|---|
| `DiscoveryProvider` | `tokens(chain, since, until)`, `pools(chain, token)` |
| `MarketDataProvider` | `swaps(...)`, `pool_snapshots(...)`, `liquidity_events(...)` |
| `OnChainProvider` | `funding_transfers(chain, wallets, until)`, `holder_snapshots(...)` |
| `NewsProvider` | `events(since, until)` |
| `SocialProvider` | `posts(token_key, since, until)` |

All are `typing.Protocol` classes with `runtime_checkable`, so adapters need no inheritance and fakes in tests satisfy them structurally.

## Adapter contract

An adapter must:

1. Return canonical records with `seen_ts` stamped from the local ingest clock.
2. Map identities to `(chain, address)`; never key anything by symbol.
3. Leave unknown fields as `None`. A vendor that returns `0` for "unknown holders" is translated to `None` in the adapter, with a unit test proving it.
4. Raise `ProviderError(retryable=..., rate_limited=...)` on failure; never return an empty list to mean "failed."
5. Record coverage (block or time ranges successfully fetched) so gaps become incomplete bars downstream.
6. Carry a unit test against a captured, anonymised payload per endpoint.
7. Read credentials only through `core.config.secret(NAME)` (environment variables). Never log them, never write them to disk.

## Transport (`providers/http.py`)

| Mechanism | Behaviour |
|---|---|
| `TokenBucket` | client-side rate limit, set below the vendor's published limit; blocking acquire |
| Retries | up to 4, exponential backoff from 1 s with 20% jitter; honours `Retry-After`; retries 429 and 5xx, fails fast on other 4xx |
| `CircuitBreaker` | opens after 5 consecutive failures for 60 s; callers get a retryable `ProviderError` instead of hammering a dead endpoint |
| Timeouts | 10 s default per request |

## Failure propagation

```
ProviderError ──► ingestor marks provider_health.ok = false
                  ──► coverage gap recorded
                      ──► bars in gap: complete = False
                          ──► window features: MISSING
                              ──► signal: NO_SIGNAL (API_FAILURE / NO_DATA / STALE_DATA)
```

A vendor outage cannot produce a signal. It produces silence with a reason.

## Streaming

WebSocket and gRPC sources (Geyser, exchange feeds) use the same canonical records through a push interface: the stream adapter calls `store.add(record)` as messages arrive, with reconnect and resume-from-slot logic. Stream and REST backfill overlap on reconnect; the data-quality dedupe (`(chain, tx_hash, log_index)`, earliest `seen_ts` kept) makes the overlap harmless.
