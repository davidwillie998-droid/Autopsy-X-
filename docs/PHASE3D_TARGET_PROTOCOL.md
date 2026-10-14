# Phase 3D: Memecoin Momentum Target Contract v1

Status: **implementation protocol; not evidence of predictive edge or profitability**.

## Why this is a separate contract

The existing Phase 3B contract (phase3b_contract.py, version 3b.1) remains frozen. It answers its original 15-minute, production-classification research question. Phase 3D defines a separate path-dependent target for the standalone memecoin momentum research system; it does not redefine Phase 3B labels, modify production signal logic, or enable live execution.

Implementation: autopsyx.research.phase3d_targets, including a bounded point-in-time liquidity join for the repository ProviderBar and PoolSnapshot records. The reproducible archive readiness command is `python -m autopsyx.research.phase3d_data_audit`; CI saves its JSON output as the `phase3d-target-readiness` artifact.

## Research question

At a timestamp when a candidate is observable, can a model identify a token/pool episode whose **net executable upside barrier is reached before its downside barrier**, after an explicit execution delay, fees, slippage and liquidity constraints?

This is narrower than “will price go up?” and does not imply that historical maximum favourable excursion (MFE) was capturable in practice.

## Frozen v1 label vocabulary

- UPSIDE_FIRST: net upside barrier is reached before the downside barrier and the touch bar passes the configured liquidity/participation gate.
- DOWNSIDE_FIRST: net downside barrier is reached first and its touch bar passes the liquidity gate.
- TIMEOUT: neither barrier is reached during a fully observed horizon; the net outcome return is measured at the horizon endpoint.
- AMBIGUOUS_SAME_BAR: OHLC high and low cross both barriers in the same bar. It is never counted as an upside success because intrabar ordering is unknown.
- ENTRY_UNAVAILABLE: no post-decision bar exists at the configured latency, or entry liquidity is missing/insufficient.
- EXIT_UNAVAILABLE: a barrier/expiry is observed but the relevant bar lacks sufficient exit liquidity.
- HORIZON_CENSORED: observed data do not cover the entire horizon. It is not silently converted into a negative or timeout.

The labeler never infers fraud. Rug-pull/fraud labels require an independently sourced, separately versioned adjudication protocol. Severe downside and inability to exit are not synonymous with confirmed fraud.

## Preregistered candidate grid

The code exposes the candidate horizons **5, 15 and 60 minutes**, and upside thresholds **5%, 10% and 20%**. They are a research grid, not a license to select the best historical result and report it as if it were the only trial. Evaluate the full declared family, disclose all runs, and account for multiple testing. Downside barrier, latency, fees, slippage, minimum liquidity and participation limit must be specified explicitly for each venue/strategy evaluation; do not infer them from a favourable backtest.

The v1 label builder uses caller-supplied proportional fee/slippage assumptions symmetrically on entry and exit and a configured expected bar interval (60 seconds by default). Because the provider omits minutes without trades, a gap is conservatively censored unless a later, separately reviewed coverage-aware protocol can establish that the interval is safe to treat as no-trade. For barrier outcomes, net_outcome_return_pct records the configured barrier threshold, not the candle high/low as if that extreme were an executable fill; for TIMEOUT, it records the cost-adjusted horizon close. MFE/MAE remain path diagnostics, not fills. Replace cost assumptions with empirically measured venue-specific costs only through a separately reviewed contract version. A bar-level liquidity gate is a conservative proxy, not a full AMM price-impact simulation.

## Timing and data integrity

- Inputs are ordered OHLC bars for **one token key and one pool key**. Do not combine pools by ticker.
- Decision time is the timestamp of the decision bar. Entry is delayed to the first subsequent bar at or after decision time plus configured latency.
- Features must be computed from information available at decision time only. Forward bars are used only to construct outcomes.
- Bar timestamps must be strictly increasing; OHLC values must be positive and internally consistent.
- price_bars_from_point_in_time_records joins bars only to matching token/pool liquidity snapshots whose event and ingestion timestamps are both no later than the bar open. It permits a last-known snapshot only within an explicit age limit. Future snapshots never backfill earlier bars; stale or missing liquidity remains missing.
- When both barriers are crossed within one OHLC bar, the outcome is ambiguous rather than guessed.
- Incomplete forward windows are censored. Gaps larger than the configured bar interval censor the label before a later barrier touch can be counted. Do not count incomplete or gapped paths as timeout failures or wins.
- MFE/MAE are stored as net-cost-adjusted path statistics. They describe the observed path; they are not a promise that a live order could capture those extrema.

## Validation protocol before model claims

1. Report label prevalence, every outcome count, and missing/censored/entry-failure/exit-failure rates by chain, venue, pool age and horizon.
2. Keep token/pool episodes grouped. Prevent the same token or same episode from crossing train/test splits where that would leak identity or path.
3. Purge training labels whose outcome intervals overlap test label intervals. The module includes an interval-overlap utility; a full model-validation pipeline must also define chronological folds and embargo rules.
4. Reconstruct the historical universe as of each decision timestamp, including dead tokens and failed launches; never backfill only surviving tokens.
5. Report precision, recall, PR-AUC and base prevalence for rare upside events; report calibration and uncertainty, not accuracy alone.
6. Evaluate executable net outcomes after fees, slippage, latency, price impact and failed exits. Compare against simple momentum and no-skill baselines.
7. Run chronological out-of-sample tests and cross-launchpad/venue tests where data allow. Keep all threshold/horizon trials in the research ledger.
8. Do not lower the existing minimum independent-token sample rule to manufacture significance. Rows are not independent tokens.
9. Run synthetic edge cases (barrier order, same-bar ambiguity, missing liquidity, latency, censoring, timestamp order and cost sensitivity) before applying labels to real archives.

## Known limitations

- OHLC cannot identify which barrier was touched first within a bar. Same-bar double touches are therefore explicitly ambiguous.
- Liquidity snapshots and a participation cap do not fully model AMM price impact, route selection, failed transactions, priority fees or MEV.
- The v1 label builder creates labels only; it does not fetch data, train a model, prove signal value, or trade.
- No real-data outcome prevalence or predictive performance is claimed until a reproducible data audit and out-of-sample evaluation have completed.

## Literature rationale

The target design follows the path-dependent labeling idea in López de Prado's *Advances in Financial Machine Learning* and standard cautions around overlapping label windows and purged validation. Those methods address label/validation design; they do not establish memecoin alpha by themselves.

- López de Prado, *Advances in Financial Machine Learning* (2018), labeling and purged cross-validation chapters: https://www.oreilly.com/library/view/advances-in-financial/9781119482086/c03.xhtml
- Cryptocurrency-specific triple-barrier application (2024): https://www.mdpi.com/2227-7390/12/5/780
