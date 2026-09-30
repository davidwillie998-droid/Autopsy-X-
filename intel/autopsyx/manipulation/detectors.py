"""Manipulation-pattern detectors.

Every flag carries evidence, confidence, affected wallets, timestamps,
transactions, methodology, and a plausible benign explanation. Unusual is not
the same as manipulated: each detector says what else could produce the
pattern.
"""
from __future__ import annotations

from collections import defaultdict
from dataclasses import dataclass, field
from typing import Sequence

from ..core.models import FundingTransfer, LiquidityEvent, LiquidityKind, PoolInfo, Side, Swap
from ..core.stats import clamp, noisy_or
from ..onchain.clusters import ClusterReport


@dataclass
class Flag:
    kind: str
    confidence: float  # 0..1: how strongly the evidence fits the pattern
    evidence: dict
    wallets: list[str]
    timestamps: list[int]
    transactions: list[str]
    methodology: str
    alternative_explanation: str

    def to_dict(self) -> dict:
        return dict(self.__dict__)


@dataclass
class ManipulationReport:
    flags: list[Flag] = field(default_factory=list)
    score: float = 0.0  # noisy-OR of flag confidences
    detectors_run: list[str] = field(default_factory=list)

    def to_dict(self) -> dict:
        return {"score": self.score, "detectors_run": self.detectors_run, "flags": [f.to_dict() for f in self.flags]}


def wash_trading(swaps: Sequence[Swap], cfg: dict, clusters: ClusterReport | None) -> list[Flag]:
    """Wallets (or clusters) with large gross volume and near-zero net position."""
    gross: dict[str, float] = defaultdict(float)
    net: dict[str, float] = defaultdict(float)
    txs: dict[str, list[str]] = defaultdict(list)
    ts: dict[str, list[int]] = defaultdict(list)
    members: dict[str, set[str]] = defaultdict(set)
    for s in swaps:
        key = clusters.cluster_of.get(s.wallet, s.wallet) if clusters else s.wallet
        gross[key] += s.quote_usd
        net[key] += s.quote_usd if s.side == Side.BUY else -s.quote_usd
        txs[key].append(s.tx_hash)
        ts[key].append(s.ts)
        members[key].add(s.wallet)
    total = sum(gross.values())
    flags = []
    for k, g in gross.items():
        if g < cfg["wash_min_gross_usd"] or total <= 0:
            continue
        round_trip = 1 - abs(net[k]) / g
        if round_trip >= cfg["wash_round_trip_ratio"]:
            share = g / total
            flags.append(Flag(
                kind="wash_trading",
                confidence=clamp(round_trip * min(1.0, share * 3)),
                evidence={"gross_usd": round(g, 2), "net_usd": round(net[k], 2), "round_trip_ratio": round(round_trip, 3),
                          "share_of_volume": round(share, 3), "wallet_count": len(members[k])},
                wallets=sorted(members[k]), timestamps=[min(ts[k]), max(ts[k])], transactions=txs[k][:20],
                methodology="Per wallet (cluster-collapsed when available): 1 - |net flow| / gross flow. High ratio "
                            "with material share of total volume matches self-dealing volume.",
                alternative_explanation="Market-making or arbitrage bots also round-trip heavily while providing "
                                        "real liquidity; check whether their fills track other venues' prices.",
            ))
    return flags


def volume_concentration(swaps: Sequence[Swap], cfg: dict, clusters: ClusterReport | None) -> list[Flag]:
    vol: dict[str, float] = defaultdict(float)
    for s in swaps:
        vol[clusters.cluster_of.get(s.wallet, s.wallet) if clusters else s.wallet] += s.quote_usd
    total = sum(vol.values())
    if total <= 0:
        return []
    top = sorted(vol.items(), key=lambda kv: kv[1], reverse=True)[: cfg["concentration_top_k"]]
    share = sum(v for _, v in top) / total
    if share < cfg["concentration_share"]:
        return []
    return [Flag(
        kind="volume_concentration",
        confidence=clamp((share - cfg["concentration_share"]) / (1 - cfg["concentration_share"]) * 0.8 + 0.2),
        evidence={"top_k": cfg["concentration_top_k"], "top_k_share": round(share, 3), "total_usd": round(total, 2),
                  "actors": len(vol)},
        wallets=[k for k, _ in top], timestamps=[swaps[0].ts, swaps[-1].ts], transactions=[],
        methodology="Share of window volume from the top-k actors (wallets, or clusters when cluster analysis ran).",
        alternative_explanation="Early-stage tokens often have few participants; a single genuine whale or an "
                                "aggregator routing many users through one address also concentrates volume.",
    )]


def creator_distribution(swaps: Sequence[Swap], creator: str | None, clusters: ClusterReport | None,
                         cfg: dict) -> list[Flag]:
    if not creator:
        return []
    linked = {creator}
    if clusters:
        root = clusters.cluster_of.get(creator)
        linked |= {w for w, r in clusters.cluster_of.items() if r == root}
    bought = sum(s.token_amount for s in swaps if s.wallet in linked and s.side == Side.BUY)
    sold = [s for s in swaps if s.wallet in linked and s.side == Side.SELL]
    sold_amt = sum(s.token_amount for s in sold)
    if not sold:
        return []
    basis = max(bought, sold_amt)
    share = sold_amt / basis if basis else 0.0
    if share < cfg["creator_sell_share"]:
        return []
    return [Flag(
        kind="creator_distribution",
        confidence=clamp(0.4 + share * 0.6),
        evidence={"linked_wallets": len(linked), "tokens_sold": sold_amt, "usd_sold": round(sum(s.quote_usd for s in sold), 2),
                  "sell_share_of_observed_position": round(share, 3)},
        wallets=sorted(linked), timestamps=[s.ts for s in sold][:50], transactions=[s.tx_hash for s in sold][:50],
        methodology="Net selling by the creator and wallets clustered with it, relative to their observed position.",
        alternative_explanation="Pre-announced treasury sales, team vesting, or funding operations; verify against "
                                "project disclosures before treating as adverse.",
    )]


def sniper_activity(swaps: Sequence[Swap], pools: Sequence[PoolInfo], total_supply: float | None,
                    cfg: dict) -> list[Flag]:
    if not pools or not total_supply:
        return []
    first_swap_block = min((s.block for s in swaps), default=None)
    if first_swap_block is None:
        return []
    created_block = first_swap_block  # launch block approximated by first observed swap
    early = [s for s in swaps if s.side == Side.BUY and s.block - created_block < cfg["sniper_blocks"]]
    amt = sum(s.token_amount for s in early)
    share = amt / total_supply
    if share < cfg["sniper_supply_share"]:
        return []
    wallets = sorted({s.wallet for s in early})
    return [Flag(
        kind="sniper_activity",
        confidence=clamp(share / (2 * cfg["sniper_supply_share"])),
        evidence={"blocks": cfg["sniper_blocks"], "supply_share": round(share, 3), "wallets": len(wallets)},
        wallets=wallets, timestamps=[s.ts for s in early][:50], transactions=[s.tx_hash for s in early][:50],
        methodology="Share of total supply bought within the first N blocks after the first observed swap.",
        alternative_explanation="Public launch-sniping bots are common and not necessarily linked to the creator; "
                                "check cluster links before inferring coordination.",
    )]


def fresh_wallet_burst(swaps: Sequence[Swap], funding: Sequence[FundingTransfer], cfg: dict,
                       fresh_ms: int) -> list[Flag]:
    first_fund: dict[str, int] = {}
    for f in sorted(funding, key=lambda f: f.ts):
        first_fund.setdefault(f.dst, f.ts)
    first_buy: dict[str, int] = {}
    for s in swaps:
        if s.side == Side.BUY:
            first_buy.setdefault(s.wallet, s.ts)
    if not first_buy:
        return []
    known = [w for w in first_buy if w in first_fund]
    if len(known) < 10:
        return []  # not enough funding coverage to say anything
    fresh = [w for w in known if 0 <= first_buy[w] - first_fund[w] <= fresh_ms]
    share = len(fresh) / len(known)
    if share < cfg["fresh_wallet_share"]:
        return []
    return [Flag(
        kind="fresh_wallet_burst",
        confidence=clamp((share - cfg["fresh_wallet_share"]) / (1 - cfg["fresh_wallet_share"]) * 0.6 + 0.2),
        evidence={"fresh_share": round(share, 3), "buyers_with_funding_data": len(known), "fresh": len(fresh)},
        wallets=sorted(fresh)[:100], timestamps=[], transactions=[],
        methodology="Share of buyers (with known funding history) first funded within the freshness window before "
                    "their first buy of this token.",
        alternative_explanation="Viral attention onboards genuinely new users who fund a wallet just to buy; "
                                "combine with shared-funding clusters before weighting heavily.",
    )]


def liquidity_inflation(events: Sequence[LiquidityEvent], creator: str | None, clusters: ClusterReport | None,
                        cfg: dict) -> list[Flag]:
    adds = [e for e in events if e.kind == LiquidityKind.ADD]
    total = sum(e.usd for e in adds)
    if total <= 0:
        return []
    by: dict[str, float] = defaultdict(float)
    for e in adds:
        by[e.provider_wallet] += e.usd
    top, amt = max(by.items(), key=lambda kv: kv[1])
    share = amt / total
    linked = creator is not None and (top == creator or (clusters is not None and
                                      clusters.cluster_of.get(top) == clusters.cluster_of.get(creator)))
    if share < cfg["single_lp_share"]:
        return []
    return [Flag(
        kind="liquidity_single_provider",
        confidence=clamp(0.3 + (0.4 if linked else 0.0) + (share - cfg["single_lp_share"])),
        evidence={"provider": top, "share_of_adds": round(share, 3), "creator_linked": linked, "total_added_usd": round(total, 2)},
        wallets=[top], timestamps=[e.ts for e in adds if e.provider_wallet == top][:20],
        transactions=[e.tx_hash for e in adds if e.provider_wallet == top][:20],
        methodology="Share of liquidity additions from a single provider, and whether that provider is creator-linked.",
        alternative_explanation="Nearly every new token launches with liquidity from one deployer; this matters "
                                "most when LP tokens are not locked or burned.",
    )]


def run_all(*, swaps: Sequence[Swap], funding: Sequence[FundingTransfer], events: Sequence[LiquidityEvent],
            pools: Sequence[PoolInfo], creator: str | None, total_supply: float | None,
            clusters: ClusterReport | None, cfg: dict, fresh_ms: int,
            extra_flags: Sequence[Flag] = ()) -> ManipulationReport:
    rep = ManipulationReport()
    for name, fn in [
        ("wash_trading", lambda: wash_trading(swaps, cfg, clusters)),
        ("volume_concentration", lambda: volume_concentration(swaps, cfg, clusters)),
        ("creator_distribution", lambda: creator_distribution(swaps, creator, clusters, cfg)),
        ("sniper_activity", lambda: sniper_activity(swaps, pools, total_supply, cfg)),
        ("fresh_wallet_burst", lambda: fresh_wallet_burst(swaps, funding, cfg, fresh_ms)),
        ("liquidity_single_provider", lambda: liquidity_inflation(events, creator, clusters, cfg)),
    ]:
        rep.flags.extend(fn())
        rep.detectors_run.append(name)
    rep.flags.extend(extra_flags)
    if clusters and clusters.cluster_risk_score and clusters.cluster_risk_score >= 0.4:
        rep.flags.append(Flag(
            kind="coordinated_cluster", confidence=clamp(clusters.cluster_risk_score),
            evidence={"label": clusters.label.value, "clustered_buy_share": clusters.clustered_buy_share,
                      "largest_cluster_buy_share": clusters.largest_cluster_buy_share},
            wallets=[w for c in clusters.clusters if len(c.wallets) > 1 for w in c.wallets][:100],
            timestamps=[], transactions=[], methodology=clusters.methodology,
            alternative_explanation="A single trader operating several wallets, or a desk splitting orders.",
        ))
    rep.score = noisy_or([f.confidence for f in rep.flags])
    return rep
