# 02. Data-Source Matrix

Candidate providers per data class. **None has been verified live in this phase**: the build container's proxy refused connections to vendor APIs. Rate limits, prices and field shapes change often, so every row is marked for verification at adapter time. Phase 2 is complete when each row has a recorded probe: latency to `seen_ts`, completeness against chain truth for a sample of blocks, and cost at target throughput.

## Matrix

| Data class | Primary candidate | Fallback / cross-check | Latency class | Gives | Cannot give | Feeds |
|---|---|---|---|---|---|---|
| Solana swaps (wallet-level) | Geyser gRPC stream (Yellowstone) via Helius, Triton or self-hosted | Helius enhanced transactions + webhooks; Bitquery DEX trades | sub-second to seconds | per-swap wallet, amounts, slot | decoded prices for exotic AMMs without program parsers | bars, participation, clusters, manipulation |
| EVM swaps (Ethereum, Base, BSC) | Node logs (`Swap` events) via Alchemy / QuickNode / own node | Bitquery; The Graph subgraphs | block time + confirmation | wallet, amounts, block | router-internal hops attributed to the router, not the user, unless traced | same |
| Pool state / liquidity | Direct pool reserves from RPC | DexScreener pairs, GeckoTerminal pools, Birdeye | seconds | reserves, TVL | CLMM depth at price (needs tick data) | liquidity, slippage, cross-venue |
| Aggregated pair stats (discovery) | DexScreener public API | GeckoTerminal trending/new pools; Birdeye token lists | seconds to a minute | new pairs, 5m/1h/24h volume and txn counts, price change | wallet identities, reliable buyer counts | discovery only |
| OHLCV history | GeckoTerminal pool OHLCV | Birdeye OHLCV; rebuild from own swap archive | historical | minute bars | wallet flow, buyer counts | backtest bootstrap only |
| Holders and concentration | Birdeye / Helius DAS token accounts (Solana); Etherscan-family or Moralis (EVM) | own balance index from transfers | minutes | holder counts, top holders | LP/burn/exchange labelling (must be done by us via address book) | participation, exhaustion |
| Native funding transfers | RPC / Helius parsed transfers | Bitquery transfers | seconds | funder graph edges | off-chain funding (CEX withdrawals share one hot wallet) | clusters |
| Launch platforms (pump.fun style bonding curves) | Program-level decoding from Geyser stream | unofficial platform endpoints (unstable, ToS-sensitive; avoid) | sub-second | creation, curve progress, migration | nothing reliable off-chain | discovery, sniper detection |
| CEX listings / delistings | Exchange announcement pages and official API announcement feeds (Binance, Coinbase, OKX, Bybit, Upbit) | Exchange official X accounts (tier 1 only when the account is verified official) | seconds to minutes | primary-source listing events | pre-announcement leaks | news tier 1 |
| CEX market data | Exchange REST/WebSocket (e.g. Crypto.com, Binance) | CoinGecko tickers | sub-second | cross-venue price, CEX volume | on-chain participation | cross-venue confirmation |
| Crypto news | RSS / APIs of established outlets; CryptoPanic aggregator | Alpha Vantage NEWS_SENTIMENT for macro/equity-adjacent | minutes | headlines, publish time, tickers | reliable token-address tagging (requires our entity resolution) | news engine |
| Project / chain announcements | Official blogs, governance forums, GitHub releases | project X accounts | minutes | upgrades, unlock schedules, governance | ground truth on execution | news tier 1 |
| Token unlocks | Project docs and vesting contracts on chain | third-party unlock calendars (tier 3) | days ahead | schedule | whether unlocked tokens get sold | news, risk |
| Macro | Official releases (BLS, Fed) | Alpha Vantage economic endpoints | scheduled | CPI, rates, payrolls | crypto-specific transmission | market regime |
| X (Twitter) | Official X API (paid tiers; sampled search limits) | licensed social data vendors | seconds to minutes | posts, authors, account age, followers, reposts | full firehose at low tiers; deleted posts after the fact | social engine |
| Telegram | MTProto client on public channels the operator joins | none | seconds | channel posts, views | private groups; member identity | social engine |
| Reddit | Official Reddit API | none | minutes | posts, comments, scores | anything off Reddit | social engine |
| Discord | Bot in servers where invited and permitted | none | seconds | messages in permitted channels | anything not explicitly permitted; scraping violates ToS | social engine (opt-in only) |
| Search interest | Google Trends (no official API; unofficial clients are fragile) | none | hours | relative interest | absolute volume, timeliness | narrative context only |

## Rules for every source

1. **Adapter per vendor.** No stage imports vendor code (doc 10).
2. **Stamp `seen_ts` at ingestion**, from the ingestor's clock, never from the vendor payload.
3. **Two sources for anything a veto depends on.** Liquidity and price must be cross-checked (`cross_source_price_tolerance`); disagreement raises `CONFLICTING_DATA` and blocks signals.
4. **Coverage records.** Each ingestor writes the block or time ranges it covered. Gaps mark bars incomplete rather than "zero volume."
5. **Tier assignment is per source, not per platform.** An exchange's own announcement page is tier 1; a random X account quoting it is tier 4.
6. **Terms of service** are part of the audit. A source that needs scraping against its terms is excluded, not worked around.

## Phase 2 probe checklist (per row)

| Probe | Pass criterion |
|---|---|
| Completeness | Swaps for 1,000 sampled blocks match chain truth to within 0.1% |
| Latency | p95 `seen_ts - ts` recorded; stage configs updated with it |
| Reorg behaviour | Provider behaviour on forked slots/blocks documented |
| Rate limit | Sustained throughput at 2x target universe size without 429s under the token bucket |
| Cost | Monthly cost at target throughput recorded |
| Field mapping | Adapter unit test against a captured, anonymised payload |
