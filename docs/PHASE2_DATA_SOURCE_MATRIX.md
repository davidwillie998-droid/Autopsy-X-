# Phase 2 Data-Source Matrix

Audit date: 2026-09-30. Status vocabulary: **AVAILABLE**, **PARTIALLY_AVAILABLE**, **UNAVAILABLE**, **REQUIRES_AUTH**, **UNKNOWN**. "Available" means reachable from the acquisition path used in this phase (a GitHub Actions runner executing `autopsyx acquire`), with the field present in real responses. The development container itself reaches no vendor host (proxy policy); every row below would be UNAVAILABLE from inside it.

## 1. Reachability audit

| Provider | Endpoint(s) | From dev container | From Actions runner | Auth | Evidence |
|---|---|---|---|---|---|
| GeckoTerminal | `/networks/{net}/new_pools`, `/trending_pools`, `/pools?sort=`, `/pools/multi/{a,b}`, `/pools/{p}/trades`, `/pools/{p}/ohlcv/minute`, `/tokens/{t}/info` | UNAVAILABLE (proxy 403) | AVAILABLE | none | live responses archived in `intel/datasets/phase2/runs/` |
| DexScreener | `/latest/dex/pairs/{chain}/{a,b}` | UNAVAILABLE | AVAILABLE | none | same archive |
| Crypto.com Exchange | `public/get-candlestick`, `public/get-trades`, `public/get-book` | UNAVAILABLE | UNKNOWN (not exercised) | none | schema probed through the session's Crypto.com connector and a fetch relay; not integrated |
| Solana public RPC (`api.mainnet-beta.solana.com`) | JSON-RPC | UNAVAILABLE | UNKNOWN (not exercised) | none | would supply funding transfers; not integrated |
| Helius | RPC, enhanced transactions | UNAVAILABLE | REQUIRES_AUTH | key | not integrated |
| Birdeye | token, trades, holders | UNAVAILABLE | REQUIRES_AUTH | key | not integrated |
| Bitquery | GraphQL DEX trades, transfers | UNAVAILABLE | REQUIRES_AUTH | key | not integrated |
| Binance / CoinGecko | REST | UNAVAILABLE | UNKNOWN | none / key | not integrated |
| Alpha Vantage | `NEWS_SENTIMENT`, `CRYPTO_INTRADAY` | UNAVAILABLE | REQUIRES_AUTH | key | reachable only through the session connector; not integrated |
| CryptoPanic | `/api/v1/posts` | UNAVAILABLE | REQUIRES_AUTH | key | not integrated |
| X API | search | UNAVAILABLE | REQUIRES_AUTH | paid key | not integrated |
| Reddit | JSON listings | UNAVAILABLE | UNKNOWN | OAuth for sustained use | not integrated |
| Telegram / Discord | MTProto / bot | UNAVAILABLE | REQUIRES_AUTH | account / invitation | not integrated |

## 2. Provider profiles (integrated sources)

### GeckoTerminal (public API v2)

| Property | Finding |
|---|---|
| Chain coverage | many networks; Phase 2 used `solana` only |
| Token / pair coverage | any indexed pool, including pump.fun bonding curves and graduated pools |
| Historical depth | OHLCV: paged with `before_timestamp`, 1,000 bars per call; 2 pages (≈33 h) fetched per pool. Trades: latest ≤ 300 of the last 24 h, no paging. Pool state and holders: current only |
| Update frequency | pools and trades refresh within about a minute; OHLCV includes the current (forming) minute |
| Timestamp format | ISO-8601 UTC with `Z` (pools, trades, holders); unix seconds (OHLCV) |
| Timestamp meaning | `block_timestamp` = block time (1 s); `pool_created_at` = pool creation; `holders.last_updated` = vendor refresh; OHLCV ts = bar open. Pool state has no event time |
| Price fields | `base_token_price_usd`, per-trade `price_from_in_usd` / `price_to_in_usd` |
| OHLC | minute, 5m/15m aggregates, day; minutes without trades omitted |
| Volume | per bar (USD), per trade (USD), pool windows m5..h24 |
| Liquidity | `reserve_in_usd` (current only) |
| Transaction counts | aggregate buys/sells and distinct buyers/sellers per window (m5..h24) |
| Buy/sell | per trade `kind` |
| Wallet level | per trade `tx_from_address` (transaction signer; for router and bot trades this is the signer, not necessarily the beneficiary) |
| Creator / deployer | `developer_address`, `developer_holding_percentage` in token info; null in every probe |
| Holders | `holders.count`, top-10 / 11-20 / 21-40 / rest distribution |
| Social | handles only (`twitter_handle`, `telegram_handle`); no activity data |
| Rate limit | published free tier ≈ 30 calls/min; the client is capped at 27/min. Measured behaviour in section 4 |
| Auth | none |
| Pagination | `page=` on pool lists; `before_timestamp` on OHLCV; none on trades |
| Error behaviour | HTTP 429 on rate limit; `{"errors": [...]}` bodies; handled by retry and PARTIAL_RESPONSE |
| Historical reconstruction | prices/volume: yes (OHLCV). Order flow and wallets: only the latest 300 trades, so historical wallet activity cannot be reconstructed beyond that. Liquidity and holders: no history |
| Known gaps | no funding transfers, no LP add/remove events, no historical liquidity, trade cap of 300, in-transaction index taken from the trade id |
| Terms | public API with attribution expectations; low-volume research use |

### DexScreener (public API)

| Property | Finding |
|---|---|
| Coverage | many chains; pairs by address, up to 30 per call |
| Historical depth | none (current state only) |
| Fields | `priceUsd`, `liquidity.usd/base/quote`, `txns` (buys/sells per m5/h1/h6/h24, no distinct wallets), `volume`, `priceChange`, `fdv`, `marketCap`, `pairCreatedAt` (unix ms) |
| Wallet level / creator / holders / OHLC | UNAVAILABLE |
| Rate limit | published ≈ 300 req/min for pair endpoints; client capped at 120/min |
| Role in Phase 2 | independent second source for price and liquidity; drives the cross-source conflict check |

## 3. Field matrix (every external field an engine reads)

| Field | Required by | Provider | Available? | Historical? | Frequency | Timestamp semantics | Failure mode |
|---|---|---|---|---|---|---|---|
| token address, chain | all | GeckoTerminal | AVAILABLE | yes | per poll | n/a | MALFORMED_ADDRESS, CHAIN_MISMATCH → record dropped |
| symbol, name | display, narrative | GeckoTerminal | AVAILABLE | yes | per poll | response time | symbol collisions reported |
| pool creation time | lifecycle, token age | GeckoTerminal | AVAILABLE | yes | per poll | pool creation (not mint) | IMPOSSIBLE_TIMESTAMP → dropped |
| total supply | market cap, sniper detector | GeckoTerminal | PARTIALLY_AVAILABLE | yes | per poll | response time | derived fdv/price (DERIVED_FIELD); MISSING when either is null |
| price | move detection, all | GeckoTerminal OHLCV + pools; DexScreener | AVAILABLE | OHLCV yes | 1 min | bar open / response time | STALE_DATA, CONFLICTING_DATA |
| OHLC bars | move, regime, exhaustion | GeckoTerminal | AVAILABLE | ≈33 h backfill + live | 1 min | bar open; seen at response | FORMING_BAR_DROPPED; incomplete outside coverage |
| USD volume per bar | volume z, regime | GeckoTerminal | AVAILABLE | yes | 1 min | bar | window MISSING if a bar lacks volume |
| trades (wallet, side, amount, USD, block) | participation, clusters, manipulation, flow features | GeckoTerminal | PARTIALLY_AVAILABLE | latest 300 only | per poll | block time; seen at first poll | PAGE_FULL, COVERAGE_GAP → flow MISSING |
| buyers / sellers / trade counts per bar | trades z, imbalance, participation | derived from trades | PARTIALLY_AVAILABLE | only inside trade coverage | 1 min | block time | MISSING outside coverage (never zero) |
| liquidity (level) | execution veto, risk sizing, slippage | GeckoTerminal `reserve_in_usd`; DexScreener `liquidity.usd` | AVAILABLE | no (forward only) | per poll | response time | STALE_DATA when old; vendor definitions differ, one source used per computation |
| liquidity change | Move Quality, exit | derived from snapshots | PARTIALLY_AVAILABLE | forward only | per poll | response time | MISSING without a snapshot inside the window |
| LP add/remove events | liquidity_single_provider detector | none | UNAVAILABLE | no | n/a | n/a | detector listed unavailable |
| holders count, top-10 share | participation, exhaustion, entry | GeckoTerminal token info | AVAILABLE | no | ≈ every 6 min per token (round robin) | vendor `last_updated` | MISSING when null |
| creator identity | creator_distribution, clusters | GeckoTerminal `developer_address` | UNAVAILABLE in practice (null in every probe) | no | per info call | n/a | detector unavailable per token |
| creator holdings | entry veto `creator_concentration_ok` | GeckoTerminal `developer_holding_percentage` | UNAVAILABLE in practice | no | per info call | n/a | veto input missing → NO_SIGNAL |
| funding transfers | cluster shared-funding edges, fresh-wallet detector | none integrated (Solana RPC candidate) | UNAVAILABLE | n/a | n/a | n/a | independence ratio UNVERIFIED; detector unavailable |
| cross-venue prices | cross-venue confirmation (H9) | only the primary pool is polled | UNAVAILABLE in this dataset | n/a | n/a | n/a | component MISSING, MQ coverage reduced |
| news events | catalyst engine (H8) | Alpha Vantage, CryptoPanic, exchange pages | REQUIRES_AUTH / not integrated | n/a | n/a | publisher vs ingestion time | catalyst "unknown, not absent" |
| social posts | attention engine (H3, H4) | X, Telegram, Reddit | REQUIRES_AUTH / UNAVAILABLE | n/a | n/a | n/a | social MISSING |
| CEX trades / candles | cross-venue for large caps | Crypto.com | UNKNOWN (not integrated) | candles: recent 50–300 | 1 min | exchange time | n/a |

## 4. Dependency map

`hypothesis → required field → source candidate → frequency → timestamp semantics → historical availability → failure mode`

| Hypothesis | Required fields | Source | Frequency | Timestamp semantics | Historical availability | Failure mode in Phase 2 |
|---|---|---|---|---|---|---|
| H1 independent wallets → continuation | trades with wallets; funding transfers | GeckoTerminal trades; funding: none | per poll | block time / first sighting | trades: last 300; funding: none | independence UNVERIFIED; H1 not testable until funding transfers exist |
| H2 volume + liquidity expansion | bar volume; liquidity series | GeckoTerminal OHLCV; pool snapshots | 1 min / per poll | bar open / response time | volume yes; liquidity forward only | testable only inside collection windows |
| H3 social + on-chain | social posts; independence | none; see H1 | n/a | n/a | none | not testable |
| H4 social frenzy without wallets | social posts; buyer growth | none; trades | n/a | n/a | none | not testable |
| H5 narrative precedes followers | move classes of many tokens | OHLCV for the universe | 1 min | bar open | yes for polled tokens | universe of 12 is too small for narrative breadth to mean much |
| H6 creator distribution → failure | creator identity; creator sells | `developer_address`; trades | per call | n/a | none in practice | not testable |
| H7 liquidity exit vs fixed stop | liquidity series; prices | snapshots; OHLCV | per poll | response time | forward only | testable only over collection windows; needs many windows |
| H8 news-confirmed vs unexplained | news with publish and ingest times | none integrated | n/a | n/a | n/a | not testable |
| H9 cross-venue confirmation | prices on ≥ 2 venues per token | multi-pool polling not done; CEX not integrated | n/a | n/a | n/a | not testable with this dataset |
| H10 combined > single class | all of the above | mixed | mixed | mixed | mixed | not testable until H1–H9 inputs exist |

Section 5 (observed behaviour of the acquisition run) is in the replay report, which also states the per-endpoint call, error, retry and latency counts measured on the runner.
