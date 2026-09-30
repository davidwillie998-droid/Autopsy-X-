# 07. Narrative Taxonomy

## Membership (`narrative/engine.py`)

Multi-label. A token belongs to every narrative its symbol, name or description matches, plus any provider hints, plus its chain ecosystem. Manual overrides by `chain:address` win over rules.

| Narrative | Keywords (baseline rules) |
|---|---|
| ai | ai, gpt, agent, neural, bot, llm, agi |
| political | trump, maga, biden, election, president, vote, kamala |
| animal | dog, doge, shib, inu, cat, pepe, frog, bonk, wif, hamster, monkey, ape |
| gaming | game, gaming, play, quest, arena |
| depin | depin, node, wireless, compute, storage |
| celebrity | elon, musk, celebrity, kanye, drake |
| cultural_event | olympics, worldcup, super bowl, halloween, christmas |
| solana_ecosystem / ethereum_ecosystem / base_ecosystem | chain membership |
| meme | every token (the universe tag; excluded from narrative exposure limits and breadth) |
| breaking-news narratives | created on demand from clustered news entities (Phase 9) |

Keyword membership is crude and knowingly so. The Phase 9 upgrade clusters tokens by co-movement and co-mention; a cluster that persists across weeks and matches no existing narrative becomes a candidate narrative for human naming.

## Momentum

Per narrative, over its members' current assessments:

```
breadth   = share of members with an up-move at class >= WATCH
momentum  = weighted mean of available parts:
            0.35 breadth
            0.20 min(1, mean volume z / 4)
            0.20 min(1, (mean buyer growth - 1) / 2)
            0.10 min(1, (mean mention velocity - 1) / 3)
            0.10 share of members launched in the last 24h
            0.05 min(1, news events per member)
```

Aggregate market cap and volume are reported alongside. Capital rotation (flows leaving one narrative's members while another's rise) is a Phase 9 measurement over the swap store.

## Phases

Computed from current momentum `m` and prior-scan momentum `m₀`, `d = m - m₀`:

| Phase | Rule |
|---|---|
| INSUFFICIENT_MEMBERS | fewer than 3 members |
| DORMANT | m < 0.1 and not rising |
| EMERGING | rising (d > 0.05) with m < 0.45, or no prior and m ≥ 0.25 |
| ACCELERATING | rising with m ≥ 0.45 |
| PEAKING | m ≥ 0.45, d within ±0.05 |
| DECAYING | falling (d < -0.05), or low and not rising |

## Leader / follower (`narrative/leadlag.py`)

Over the last 120 aligned 1-minute log returns for every pair of tokens:

1. Find the lag in ±15 bars maximising `corr(a_t, b_{t+lag})`.
2. Keep the link only if that correlation ≥ 0.3, the lag is nonzero, and it beats same-bar correlation by ≥ 0.1. The margin matters: two tokens trending up together over the same window correlate at every lag, and without it every co-trending pair looks like a leader and a follower.
3. Roles: LEADER leads at least one link and follows none; FOLLOWER follows a link and is in an abnormal up-move itself; LAGGARD follows but is not moving yet; ISOLATED_MOVE otherwise.

A follower is never signalled on the leader's strength. It must carry its own wallet growth, independence, and liquidity (entry condition 11, a veto).

Correlation at a lag in one sample says returns lined up; it does not establish that one token drives another. H5 tests whether narrative-level acceleration predicts secondary-token acceleration out of sample.

## Social attention within narratives (`social/attention.py`)

The unit of evidence is the *effective independent author*: posts are grouped by 3-word shingle Jaccard ≥ 0.8, each content group counts once for its heaviest author, and authors are weighted by account age (0.3 if younger than 30 days) and log followers. Reposts are excluded.

```
artificial_attention = 0.30 duplicate_ratio + 0.20 repost_ratio + 0.20 min(1, 5 * author HHI)
                     + 0.15 new_account_share + 0.15 (1 - effective_authors / mentions)
```

A thousand copies from ten accounts score as roughly ten weak authors and a high artificial-attention score. That score feeds manipulation (as `social_engagement_anomaly`) and exhaustion ("social frenzy" when mentions outrun effective authors 3 to 1).
