# 05. Manipulation-Detection Methodology

## Principles

1. **Unusual is not manipulated.** Every detector names the benign mechanism that produces the same footprint.
2. **Patterns, not intent.** Labels describe structure: `independent`, `concentrated`, `coordinated-looking`, `highly-correlated`, `suspicious-pattern`. The system never asserts fraud, and nothing it outputs should be read as an accusation against a person.
3. **Every flag is auditable.** Each `Flag` carries `evidence` (the numbers), `confidence`, `wallets`, `timestamps`, `transactions`, `methodology`, `alternative_explanation`.
4. **Detectors that did not run are listed as not run.** `detectors_run` distinguishes "checked, clean" from "not checked."

## Wallet graph (`onchain/clusters.py`)

Nodes are wallets. Edges, each stored with evidence and transaction hashes:

| Edge | Rule | Default |
|---|---|---|
| shared_funding | two trading wallets whose *first observed* native funding came from the same source within a window | 6 h |
| creator_link | wallet first funded by the token creator | |
| direct_transfer | native transfer between two wallets that both trade the token | |
| synchronized_trades | pair of wallets whose buys land within a tolerance of each other at least k times | 2 s, k = 3 |

Union-find over the edges yields clusters. Known infrastructure (exchange hot wallets, bridges, routers) is excluded as a funder via the address book; without that list, every wallet withdrawn from the same exchange looks related.

```
clustered_share = buy USD from multi-wallet clusters / total buy USD
largest_share   = buy USD of the largest multi-wallet cluster / total buy USD
CLUSTER_RISK    = min(1, 0.5 * clustered_share + 0.75 * largest_share)
```

| Label | Rule |
|---|---|
| independent | risk < 0.15 |
| suspicious-pattern | risk ≥ 0.4 with synchronized trades AND shared funding or creator links |
| highly-correlated | synchronized trades, risk ≥ 0.3 |
| coordinated-looking | synchronized trades (lower risk), or shared funding / creator links |
| concentrated | multi-wallet clusters from direct transfers only |

## Detectors (`manipulation/detectors.py`)

| Detector | Evidence and formula | Confidence | Benign explanation |
|---|---|---|---|
| wash_trading | per actor (cluster-collapsed): round-trip = 1 - \|net\| / gross; flag when ≥ 0.8 and gross ≥ $5k | round-trip × min(1, 3 × volume share) | market makers and arbitrage bots round-trip while supplying real liquidity; check fills against other venues |
| volume_concentration | top-5 actors' share of window volume ≥ 50% | scaled from threshold to 1, floor 0.2 | early tokens have few participants; aggregators route many users through one address |
| creator_distribution | creator plus creator-clustered wallets: tokens sold / max(bought, sold) ≥ 10% | 0.4 + 0.6 × share | disclosed treasury or vesting sales |
| sniper_activity | supply share bought in the first 3 blocks after the first observed swap ≥ 20% | share / 40% | public sniping bots unrelated to the creator |
| fresh_wallet_burst | share of buyers (with known funding) funded < 24 h before first buy ≥ 60%; needs ≥ 10 such buyers | scaled, floor 0.2 | viral attention onboards genuinely new users |
| liquidity_single_provider | one wallet supplied ≥ 90% of LP adds | 0.3, +0.4 if creator-linked | nearly every launch; matters when LP is not locked or burned |
| coordinated_cluster | cluster risk ≥ 0.4 | cluster risk | one trader running several wallets; a desk splitting orders |
| social_engagement_anomaly | artificial attention ≥ 0.6 (doc 07 §social) | 0.6 × score | organised genuine communities post templated content |

`manipulation_score = 1 - Π(1 - confidence_i)` (noisy-OR). Correlated flags (wash trading and coordinated cluster on the same wallets) double count under noisy-OR; this biases toward caution and is listed as a known limitation. A calibrated replacement is P(MANIPULATION) from doc 08 once labelled outcomes exist.

## Ground truth problem

There is no public, labelled dataset of manipulated memecoin moves. Validation therefore uses three weaker sources, reported separately:

1. **Synthetic injections.** Known wash patterns inserted into real historical swap streams; measures recall at a controlled false-positive rate.
2. **Outcome proxies.** Tokens whose liquidity was removed by the creator within 24 h, or which lost > 90% within 48 h. Precision of flags against these proxies, with the caveat that organic tokens also die.
3. **Manual review.** A stratified sample of flagged and unflagged moves reviewed by a human with the evidence panel; inter-rater agreement recorded.

A detector whose flags do not separate outcome proxies from controls at the chosen threshold gets its weight reduced or its threshold raised through a versioned config change.
