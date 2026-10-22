# Memecoin Data Readiness: Evidence Review and Gate Design

**Status:** Research/design proposal. This document does not certify the current dataset as ready and does not authorize model training or live trading.

**Scope:** Standalone Solana memecoin momentum-intelligence project. This is not the Autopsy X / FX execution system.

## Executive finding

Data readiness is a property of the exact decision-time dataset and intended prediction horizon, not a count of downloaded rows. The current recorded audit (20,238 OHLCV bars across six archives; 71 usable-liquidity bars, about 0.35%; 1,088 liquidity snapshots; zero pools meeting the existing contiguous 5m/15m/60m requirements) indicates a likely coverage failure if reproduced. Recompute these figures from immutable archives before treating them as current facts.

Do not lower existing minimums to obtain a green status. First establish why coverage is low: source/API limitations, failed backfill, token/pool identity mismatches, timestamp semantics, incomplete archive manifests, liquidity definitions, or genuinely illiquid pools. A pool that is not measurable is not evidence of a liquid pool.

## What the literature establishes

### 1. Survivorship and token-lifecycle bias are material

Ammann, Burdorf, Liebi and Stöckl, *Survivorship and Delisting Bias in Cryptocurrency Markets* (2022), study 3,904 cryptocurrencies from 2014–2021. They report substantial sample-selection distortion: annualized survivorship/delisting bias is estimated at 0.93% for value-weighted portfolios and 62.19% for equal-weighted portfolios; the size premium is overestimated by roughly 50% in a survivor-conditioned sample. The exact magnitudes do not transfer directly to newly launched Solana memecoins, but the methodological lesson does: do not construct historical universes only from tokens that still exist or are currently popular.

Source: https://alexandria.unisg.ch/entities/publication/ed11eb12-4cd1-4e08-b3a4-f577ad6e4a66/full

Gandal et al., *The Rise and Fall of Cryptocurrency Coins and Tokens* (2021), explicitly measure abandonment and resurrection rather than treating disappearance as a clean, permanent state. Their older, broader crypto sample is not a Solana-memecoin benchmark, but it supports tracking token lifecycle states and preserving inactive tokens in historical cohorts.

Source: https://doi.org/10.1007/s10203-021-00329-8

**Design implication:** keep a point-in-time universe ledger with pool/token identity, first-seen time, source-observed time, lifecycle state, and explicit exclusion reason. Never silently drop a token because it later became inactive, disappeared from an API, or failed a current-liquidity filter. Eligibility must be computed using only information available at the decision time.

### 2. OHLCV is not a substitute for executable liquidity

Xu et al., *SoK: Decentralized Exchanges (DEX) with Automated Market Maker (AMM) Protocols* (ACM, 2023), explain that AMM slippage depends on trade size relative to pool size and on the pool's pricing function. Small pools amplify the price impact of a given trade.

Source: https://dl.acm.org/doi/fullHtml/10.1145/3570639

Alhaidari et al., *SolRPDS: A Dataset for Analyzing Rug Pulls in Solana Decentralized Finance* (ACM CODASPY 2025), analyze Solana activity from 2021–2024, including 62,895 suspicious liquidity pools. Their dataset tracks liquidity additions/removals, withdrawn amounts, inactivity and last interactions. The authors emphasize that raw transactions alone do not provide the complete view needed to identify liquidity-drain patterns.

Source: https://doi.org/10.1145/3714393.3726487

**Design implication:** separate these concepts in storage and reports:
- **Bar coverage:** expected versus observed OHLCV intervals.
- **Observed pool liquidity:** reserve/depth snapshots with source and timestamp.
- **Executable depth / impact:** estimated output for a specified notional using the relevant AMM curve and fee model, if the required pool state is available.
- **Liquidity events:** add/remove events and their observed timestamps.
- **Tradability:** a decision-time result based on liquidity, route availability, expected price impact, fees, and stale-data checks.

A non-zero volume field or a single liquidity snapshot does not prove that a strategy can enter and exit at a reasonable cost.

### 3. Point-in-time availability matters as much as event time

The acquisition pipeline records local receive time because a record should become available to replay only when it was first observed by the collector, not merely when the on-chain event occurred. Preserve both event/block time and collector-observed time. Historical replay must not use a future-observed value to make an earlier decision.

**Design implication:** all joins for model features and eligibility must be backward as-of joins on the collector's observed/available time. Reject or quarantine rows with impossible timestamp order, unknown clock semantics, duplicate keys with conflicting values, or source timestamps later than the decision time. Do not fill a missing OHLCV interval with a synthetic zero-volume bar unless the source explicitly defines that convention; record missingness separately.

### 4. Data readiness and strategy profitability are separate claims

A dataset can pass structural validation and still have no predictive edge. Conversely, a profitable-looking backtest cannot repair missing observations, selection bias, or impossible execution assumptions.

**Design implication:** use independent statuses:
- \`ACQUISITION_VALID\`: raw records, run manifest, source responses, and hashes are internally consistent.
- \`COVERAGE_VALID\`: declared denominators and coverage thresholds pass for each required horizon and cohort.
- \`POINT_IN_TIME_VALID\`: event/observed times and joins are leakage-safe.
- \`LIQUIDITY_VALID\`: decision-time liquidity and executable-cost evidence pass the existing policy.
- \`LABELS_VALID\`: forward outcomes are complete, correctly aligned, and censoring is explicit.
- \`MODEL_EVALUATION_ALLOWED\`: all required data gates pass; this is permission to evaluate, not evidence of edge.
- \`LIVE_TRADING_ALLOWED\`: remains a separate, explicitly approved gate and must not be inferred from data readiness.

## Recommended audit contract

For every run and each token/pool cohort, report counts and denominators, not only percentages.

1. **Archive integrity**
   - Run ID is unique and never silently reused.
   - Every raw file is present in the manifest with SHA-256, byte size, source, request/response status, and collection timestamps.
   - Manifest row count equals parsed row count, with malformed and rejected rows reported separately.
   - Re-running the audit over the same immutable archive produces identical results.

2. **Identity and deduplication**
   - Use chain + pool address + token mint + interval as appropriate; do not identify a pool by symbol/name.
   - Report exact duplicates separately from conflicting duplicates.
   - Keep a stable mapping between token mint, pool, quote/base assets, and venue.
   - Explain all exclusions; never silently discard failed, inactive, or delisted tokens.

3. **OHLCV integrity and coverage**
   - For each pool, compute expected intervals from its declared eligible observation window; exclude pre-launch time from the denominator.
   - Report observed bars, missing intervals, duplicate intervals, malformed bars, stale bars, longest contiguous run, and coverage ratio.
   - Validate finite positive prices, OHLC ordering (\`low <= open/close <= high\`), non-negative volume, and timestamp alignment.
   - Report coverage separately for 5m, 15m and 60m decision horizons, and by age/liquidity cohort. Do not aggregate a healthy pool into a failing pool's denominator without showing per-pool results.

4. **Liquidity and execution evidence**
   - Preserve reserve/depth snapshots and liquidity add/remove events with event and observed times.
   - Report snapshot age at decision time, missing snapshot rate, depth in quote currency, quote-asset identity, and source.
   - Where pool state supports it, estimate buy and sell output for fixed notional tiers using the actual AMM curve and fees; report expected price impact and round-trip costs. Do not assume constant-product mechanics for pools that use another curve.
   - A pool with missing depth, stale state, no valid route, or unmeasurable impact is \`UNKNOWN/FAIL\`, not liquid by default.
   - Keep the project's existing minimum thresholds unchanged until an evidence-backed change is separately reviewed.

5. **Labels and temporal evaluation**
   - Every label must identify decision timestamp, feature-availability cutoff, outcome horizon, exit-price convention, and whether the outcome is censored due to missing/stale data or pool death.
   - Do not silently drop tokens that die or lose liquidity before the horizon; report censoring and failure outcomes explicitly.
   - Use chronological train/validation/test splits or walk-forward evaluation. No random row shuffle across time. Keep all rows for a token/pool episode within the correct temporal fold and avoid overlapping forward-label leakage across boundaries.
   - Fit imputation, scaling, feature selection, and thresholds on training data only.
   - Record the number of strategies/parameter variants tested; a selected backtest is not an unbiased final estimate if the same period was repeatedly searched.

## Required report output

The audit should produce a machine-readable JSON report and a human-readable summary with:
- code commit, request/run ID, manifest hash, archive IDs and audit timestamp;
- expected/observed/rejected/missing counts with denominators;
- per-pool and per-cohort 5m/15m/60m coverage;
- longest contiguous run and gap distribution;
- liquidity snapshot freshness and missingness;
- liquidity add/remove coverage and observed liquidity-depletion events;
- point-in-time violations and duplicate/conflict counts;
- label completeness/censoring counts;
- each gate's \`PASS\`, \`FAIL\`, or \`UNKNOWN\` status with explicit reason;
- an overall status that fails closed if any required gate is \`FAIL\` or \`UNKNOWN\`.

Do not report a single blended score that lets good OHLCV coverage compensate for missing liquidity evidence. Each required gate is independently binding.

## Immediate work order

1. Reproduce the previous audit from the six immutable archives and publish the exact denominator/formulas behind “usable-liquidity bar.”
2. Inspect the acquisition manifest and per-provider errors to find why backfill/snapshots do not produce enough contiguous, usable observations.
3. Check whether the request run ID already exists before creating a new acquisition; use a new immutable run ID for any fresh attempt.
4. Correct collection/normalization defects only where the evidence identifies them. Do not loosen thresholds or broaden the token universe merely to hit counts.
5. Re-run deterministic archive integrity, provenance verification, and coverage/liquidity audits.
6. Keep model training blocked until all required gates pass; keep live trading separately blocked pending evaluation and explicit authorization.

## Source-quality and transfer limitations

The cited work provides strong methodological reasons to preserve dead assets, measure AMM price impact, and track liquidity withdrawals. Most studies use broader crypto universes or historical Solana pools rather than this exact live memecoin collector. They do **not** determine the project's numeric coverage thresholds, guarantee signal profitability, or justify transferring results directly to this dataset. Thresholds must remain tied to the existing project contract unless a separately reviewed empirical calibration supports a change.
