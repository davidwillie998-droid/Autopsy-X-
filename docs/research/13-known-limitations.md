# 13. Known Limitations

Stated plainly so nobody mistakes the current system for more than it is.

## Evidence

* **No historical validation exists.** Every threshold and weight is a hypothesis. The engine has run only on synthetic scenarios built to exercise its code paths.
* **No live data source has been verified.** The build environment could not reach vendor APIs; the data-source matrix is a research plan, not an audit result.
* **Confidence is uncalibrated.** `agreement × coverage` orders signals by evidence agreement. It is not a probability of anything.

## Measurement

* **Wallets are not people.** One actor can run a thousand wallets funded through a CEX (which our graph cannot see through), and one CEX or aggregator address can represent thousands of people. Cluster analysis reduces this error; it does not remove it.
* **Funding coverage bounds cluster detection.** Wallets funded off-chain or through privacy tools show no shared-funding edge. `independence_ratio` is therefore biased upward.
* **Router trades mislabel side and wallet.** Swaps routed through aggregators can attribute the trade to the router contract. Parsers must unwrap routes per venue.
* **CPMM slippage is wrong for concentrated liquidity.** CLMM pools can have far more or far less depth near price than TVL suggests. Estimates there carry status UNVERIFIED.
* **Holder data depends on exclusions.** Top-10 concentration is meaningless until LP, burn, locker and exchange addresses are excluded through the address book.
* **Young tokens are UNCLASSIFIED.** The system does not score abnormality without history. Many of the largest memecoin moves happen in the first hours, exactly where this system is weakest. A same-age cohort baseline is the planned remedy.
* **Keyword narratives misassign.** "cat" matches tokens unrelated to cats; novel narratives match nothing until named.
* **Lead/lag is correlational** and sample-dependent. With 120 bars and many token pairs, some links will appear by chance; the advantage margin reduces but does not eliminate false links. Multiple-comparison control is a Phase 9 item.
* **Noisy-OR double counts correlated flags**, making the manipulation score conservative.

## Information

* **News timing depends on the fastest source we have.** If the market hears first through a channel we do not ingest, NEWS_FIRST moves look like MOVE_FIRST and the edge is illusory.
* **Social APIs sample.** Low-tier platform access sees a fraction of posts. Velocity ratios survive sampling if the fraction is stable; absolute counts do not.
* **Private channels are invisible.** Coordinated groups that organise off public platforms leave only their on-chain footprint.
* **Sentiment is not implemented.** The field reports MISSING until a model is validated against labelled posts.

## Execution

* **Backtest fills are models.** Priority fees, MEV sandwiching, failed transactions and chain congestion are approximated by a latency bar, a priority fee and a failed-exit flag. Real Solana and EVM execution in hot tokens is worse than any of these.
* **Exits are the binding constraint.** In a collapsing pool, the modelled exit price is optimistic by construction; `failed_exit_rate` measures how often that optimism matters.
* **No execution layer exists.** Phase 14 is optional and has not started.

## Scope

* The system does not predict new launches, and does not try to.
* It does not give personal financial advice or tell anyone to buy. It reports evidence and its limits.
