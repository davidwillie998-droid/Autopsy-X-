# 06. News-Event Taxonomy

## Event record

`EVENT_ID, TIMESTAMP (publisher), SEEN_TS (ingestion), SOURCE, SOURCE_TIER, HEADLINE, SUMMARY, ENTITIES, TOKENS (chain:address), CHAINS, NARRATIVE, EVENT_TYPE, SENTIMENT, NOVELTY, STORY_ID`. Computed at assessment time: `CREDIBILITY, MARKET_RELEVANCE, EXPECTED_IMPACT`. Measured afterwards and stored in a separate table so it can never feed features: `ACTUAL_MARKET_REACTION`.

## Event types (`news/taxonomy.py`)

| Type | Expected first-order direction for the named token | Examples |
|---|---|---|
| LISTING | + | CEX spot or perp listing, major DEX aggregator inclusion |
| DELISTING | - | removal, trading suspension |
| PARTNERSHIP | + | integration, collaboration |
| PROTOCOL_UPGRADE | + | mainnet, hard fork, v2 |
| TOKEN_UNLOCK | - | vesting cliff |
| BURN | + | supply burn |
| SUPPLY_CHANGE | 0 | mint authority change, migration |
| GOVERNANCE | 0 | proposal, vote |
| EXPLOIT | - | hack, drain, vulnerability |
| REGULATORY | 0 | enforcement, lawsuit, ban (sign depends on content) |
| ETF | + | filing, approval |
| INSTITUTIONAL | + | treasury purchase, fund entry |
| MACRO | 0 | CPI, rates, payrolls |
| WHALE_MOVEMENT | 0 | large transfer to exchange |
| CELEBRITY_MENTION | + | public figure references the token |
| CULTURAL_EVENT | + | event that spawns a meme |
| PROJECT_ANNOUNCEMENT | + | roadmap, product |
| CHAIN_ANNOUNCEMENT | 0 | chain-level news affecting an ecosystem |
| OTHER | 0 | |

Classification starts with transparent keyword rules (`classify_headline`). A learned classifier replaces them only if it beats the rules on a hand-labelled holdout.

## Source reliability tiers

| Tier | Definition | Prior credibility |
|---|---|---|
| 1 PRIMARY | Exchange announcement pages, official project/chain channels verified as official, regulators | 0.95 |
| 2 ESTABLISHED | Newsrooms with editorial standards and published corrections | 0.80 |
| 3 AGGREGATOR | Aggregators and crypto-native outlets that mostly republish | 0.55 |
| 4 UNVERIFIED | Arbitrary social posts, Telegram, anonymous accounts | 0.20 |

Priors get recalibrated per source from observed accuracy: the share of its reports later confirmed by a tier-1 source, and the share retracted.

## Confirmation

A story is **confirmed** when any report comes from tier 1 or 2, or when at least two *independent* tier-3 sources carry it. Tier-4 posts never confirm anything, however many there are. Unconfirmed stories cap credibility at 0.3 and add `NEWS_UNVERIFIED` to the signal's risk flags.

Stories group reports by `story_id` (entity + event type + time proximity during ingestion). Novelty = 1 for the first report of a story, decaying for later reports.

## News-to-move timing (`news/catalyst.py`)

Around the move onset, search token-tagged events from 60 minutes before to 15 minutes after.

| Class | Rule |
|---|---|
| NEWS_FIRST | earliest report of the most credible story published > 60 s before onset |
| SIMULTANEOUS | within ±60 s of onset |
| MOVE_FIRST | move began > 60 s before the first report |
| NO_IDENTIFIED_CATALYST | no token-tagged event in window |
| CONFLICTING_INFORMATION | stories in window imply opposite directions |

Two leads are reported:

* `lead_ms = onset - publisher ts` answers "did the news cause it?"
* `seen_lead_ms = onset - ingestion ts` answers "could we have traded it?"

A NEWS_FIRST move with negative `seen_lead_ms` means the market heard before the system did; the catalyst explains the move but offered no edge. MOVE_FIRST moves with a later listing announcement are the signature of leaked information and get studied separately (H8).

## Failure modes

* Publisher timestamps can be backdated or updated in place. The ingestor keeps the first-seen value and both clocks.
* Token tagging from headlines is ambiguous (symbol collisions). Events map to `chain:address` through entity resolution; unresolved events stay untagged rather than tagged by symbol.
* Macro events are not token-tagged; they feed the market-regime context, not the per-token catalyst.
