"""Feature store registry: one authoritative definition per feature.

docs/research/03-feature-dictionary.md is generated from this table
(``python -m autopsyx features``), so documentation cannot drift from code.
"""
from __future__ import annotations

from dataclasses import dataclass


@dataclass(frozen=True)
class FeatureSpec:
    name: str
    definition: str
    source: str
    calculation: str
    frequency: str
    lookback: str
    missing: str
    failure_mode: str
    test: str
    rationale: str


_M = "MISSING (never 0)"

FEATURES: list[FeatureSpec] = [
    FeatureSpec("token_age", "Time since first observed pool creation", "discovery: PoolInfo.created_ts",
                "as_of - min(pool.created_ts)", "per scan", "n/a", _M, "late discovery overstates age of relaunched tokens",
                "unit: fixed timestamps", "young tokens have no baseline; many rules depend on age"),
    FeatureSpec("market_cap", "Price x total supply", "swaps + TokenMeta.total_supply", "close * total_supply",
                "1m", "latest", "MISSING if supply unknown", "total != circulating supply; treat as FDV-like",
                "unit", "normalises volume"),
    FeatureSpec("fdv", "Fully diluted value", "TokenMeta.total_supply", "close * max supply", "1m", "latest", _M,
                "max supply often unavailable for memecoins", "unit", "compare with market_cap"),
    FeatureSpec("liquidity", "Sum of latest per-pool liquidity (USD)", "PoolSnapshot", "sum(latest per pool)",
                "provider cadence", "latest", _M, "vendor liquidity definitions differ; CLMM depth != TVL",
                "unit + cross-source check", "execution capacity"),
    FeatureSpec("price_return_{n}", "Log return over n closed bars", "swaps -> bars", "ln(close_t / close_{t-n})",
                "1m", "n bars", "MISSING if a bar in window is incomplete", "stale bars carry previous close",
                "unit: synthetic bars", "raw momentum"),
    FeatureSpec("price_z_{n}", "Robust z of n-bar return vs own history", "bars",
                "(r - median(hist)) / (1.4826 * MAD(hist)), hist = prior n-bar returns, stride n/4",
                "1m", "baseline_bars (default 1440)", "INSUFFICIENT_HISTORY below min_baseline_samples",
                "regime shifts inflate z; baseline excludes the current window", "unit + leakage test",
                "abnormality relative to the coin itself"),
    FeatureSpec("price_percentile_{n}", "Percentile of n-bar return in own history", "bars", "rank(r, hist)",
                "1m", "baseline_bars", "INSUFFICIENT_HISTORY", "same as price_z", "unit", "distribution-free check on z"),
    FeatureSpec("vol_adjusted_return_{n}", "Return scaled by 1-bar sigma", "bars", "r / (MAD(1-bar r) * sqrt(n))",
                "1m", "baseline_bars", "INSUFFICIENT_HISTORY", "assumes sqrt-time scaling", "unit", "cross-token comparability"),
    FeatureSpec("atr_normalized_{n}", "Price change in ATR units", "bars", "(close_t - close_{t-n}) / ATR(14)",
                "1m", "14 bars", _M, "ATR collapses in dead tokens", "unit", "range-relative move size"),
    FeatureSpec("price_acceleration", "Change in n-bar return vs previous n bars", "bars", "r_n(t) - r_n(t-n)",
                "1m", "2n bars", _M, "noisy at n=1", "unit", "is the move speeding up"),
    FeatureSpec("volume_{n}", "USD volume over n bars", "swaps", "sum(quote_usd)", "1m", "n bars",
                "MISSING if window overlaps data gap", "wash volume inflates it", "unit", "activity"),
    FeatureSpec("volume_z_{n}", "Robust z of log1p volume vs history", "bars", "robust_z(log1p(v), hist)", "1m",
                "baseline_bars", "INSUFFICIENT_HISTORY", "wash volume", "unit", "volume confirmation"),
    FeatureSpec("volume_acceleration", "Volume now / volume previous window", "bars", "v_n(t) / v_n(t-n)", "1m",
                "2n bars", "MISSING if previous volume is 0", "", "unit", "confirmation trend"),
    FeatureSpec("buy_sell_imbalance", "(buy - sell) / (buy + sell) USD", "swaps", "per window", "1m", "n bars",
                "MISSING if no volume", "router trades can mislabel side", "unit", "order-flow pressure"),
    FeatureSpec("unique_buyers", "Distinct buying wallets in window", "swaps", "count distinct", "per scan",
                "participation window", "0 is a real value when coverage is complete", "sybil wallets",
                "unit", "breadth"),
    FeatureSpec("unique_sellers", "Distinct selling wallets in window", "swaps", "count distinct", "per scan",
                "participation window", "as above", "", "unit", "supply side breadth"),
    FeatureSpec("buyer_growth", "Unique buyers now vs median of prior windows", "swaps", "(now+1)/(median+1)",
                "per scan", "baseline_windows x window", "INSUFFICIENT_HISTORY", "sybil wallets", "unit", "H1"),
    FeatureSpec("new_wallet_share", "Share of buyers with no prior trade in this token", "swaps", "new / buyers",
                "per scan", "all history", "MISSING if no buyers", "history truncation marks old wallets new",
                "unit", "fresh demand"),
    FeatureSpec("holder_growth", "Relative change in holder count over window", "HolderSnapshot",
                "holders_t / holders_{t-w} - 1", "provider cadence", "window", _M,
                "dust airdrops inflate holders", "unit", "adoption"),
    FeatureSpec("top10_holder_pct", "Supply share of top-10 holders", "HolderSnapshot", "provider", "provider cadence",
                "latest", _M, "LP/burn/exchange addresses must be excluded upstream", "unit", "concentration risk"),
    FeatureSpec("creator_pct", "Supply share held by creator", "HolderSnapshot", "provider", "provider cadence",
                "latest", _M, "creator may hold via other wallets (see clusters)", "unit", "H6"),
    FeatureSpec("wallet_cluster_score", "Buy-volume share held by multi-wallet clusters", "swaps + funding",
                "0.5*clustered_share + 0.75*largest_cluster_share, capped at 1", "per scan", "all history", _M,
                "exchange hot wallets as funders create false clusters; maintain ignore list",
                "unit: synthetic clusters", "independence of demand"),
    FeatureSpec("independence_ratio", "Effective (cluster-collapsed) buyers / unique buyers", "clusters", "ratio",
                "per scan", "participation window", "MISSING if clusters not run", "funding coverage gaps bias up",
                "unit", "H1"),
    FeatureSpec("wash_score", "Max wash-trading flag confidence", "swaps + clusters",
                "1 - |net|/gross per actor, weighted by volume share", "per scan", "manipulation window", "0 only if detector ran",
                "MM bots round-trip legitimately", "unit", "artificial volume"),
    FeatureSpec("manipulation_score", "Noisy-OR of all flag confidences", "manipulation engine", "1 - prod(1 - c_i)",
                "per scan", "manipulation window", "detectors_run lists what was checked", "correlated flags double count",
                "unit", "veto input"),
    FeatureSpec("social_velocity", "Mentions now / median of prior windows", "SocialPost", "(now+1)/(median+1)",
                "per scan", "baseline_windows x window", "MISSING if no provider", "platform API sampling", "unit", "H3/H4"),
    FeatureSpec("effective_author_velocity", "Effective independent authors vs baseline", "SocialPost",
                "near-duplicate collapse, author weight by age/followers", "per scan", "as above", _M,
                "follower counts are purchasable", "unit", "attention vs artificial attention"),
    FeatureSpec("artificial_attention_score", "Composite of duplication/concentration/new accounts", "SocialPost",
                "0.3 dup + 0.2 repost + 0.2 min(1, 5*HHI) + 0.15 new + 0.15 gap", "per scan", "window", _M,
                "genuine raids look similar", "unit", "H4"),
    FeatureSpec("news_catalyst_score", "Timing x credibility x direction consistency", "NewsEvent",
                "base(timing) * credibility, 0 if direction inconsistent", "event-driven", "before/after windows",
                "0 with NO_IDENTIFIED_CATALYST (explicit class)", "publisher timestamps can be backdated", "unit", "H8"),
    FeatureSpec("narrative_score", "Max breadth among the token's narratives", "narrative engine",
                "fraction of members in abnormal up-move", "per scan", "current scan", "MISSING below min members",
                "keyword taxonomy misassigns", "unit", "H5"),
    FeatureSpec("cross_venue_score", "Share of venues agreeing on direction", "PoolSnapshot",
                "max(up, down)/venues over 15 bars", "per scan", "15 bars", "MISSING with <2 venues",
                "arbitrage makes this near 1 by construction", "unit", "H9"),
    FeatureSpec("est_slippage", "CPMM price impact for reference trade + fee", "liquidity", "d / (L/2) + fee",
                "per scan", "latest", _M, "CLMM/orderbook: approximation, status UNVERIFIED", "unit", "execution"),
    FeatureSpec("market_regime", "Rule-based regime label", "regime engine", "priority rules", "per scan", "240 bars",
                "UNKNOWN", "rules are hypotheses", "unit + replay", "context for every signal"),
    FeatureSpec("move_quality_score", "Weighted support minus penalties", "move quality engine",
                "sum(w c)/sum(w) - sum(p q)/sum(p) over available", "per scan", "current", "coverage reported",
                "weights unvalidated", "unit", "H10"),
]


def markdown() -> str:
    lines = ["| Feature | Definition | Source | Calculation | Frequency | Lookback | Missing data | Failure mode | Test | Rationale |",
             "|---|---|---|---|---|---|---|---|---|---|"]
    for f in FEATURES:
        lines.append("| " + " | ".join(x.replace("|", "\\|") for x in (
            f"`{f.name}`", f.definition, f.source, f.calculation, f.frequency, f.lookback, f.missing,
            f.failure_mode or "-", f.test, f.rationale)) + " |")
    return "\n".join(lines)
