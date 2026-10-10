"""Wallet cluster detection over a funding / transfer / timing graph.

Edges are explicit and each carries its evidence, so every cluster can be
explained wallet by wallet. Labels are descriptive of *patterns*, never of
intent: a cluster can be one person's hot wallets, a market maker, a launch
bot, or a trading desk.
"""
from __future__ import annotations

from collections import defaultdict
from dataclasses import dataclass, field
from enum import Enum
from typing import Iterable, Sequence

from ..core.models import FundingTransfer, Side, Swap


class ClusterLabel(str, Enum):
    INDEPENDENT = "independent"
    CONCENTRATED = "concentrated"
    COORDINATED_LOOKING = "coordinated-looking"
    HIGHLY_CORRELATED = "highly-correlated"
    SUSPICIOUS_PATTERN = "suspicious-pattern"


@dataclass(frozen=True)
class Edge:
    a: str
    b: str
    kind: str  # shared_funding | direct_transfer | synchronized_trades | creator_link
    evidence: str
    tx_hashes: tuple[str, ...] = ()


@dataclass
class Cluster:
    cluster_id: str
    wallets: list[str]
    edges: list[Edge]
    buy_usd: float = 0.0
    sell_usd: float = 0.0
    contains_creator: bool = False

    def to_dict(self) -> dict:
        return {
            "cluster_id": self.cluster_id, "wallets": self.wallets, "buy_usd": self.buy_usd,
            "sell_usd": self.sell_usd, "contains_creator": self.contains_creator,
            "edges": [e.__dict__ for e in self.edges],
        }


@dataclass
class ClusterReport:
    clusters: list[Cluster]
    cluster_of: dict[str, str]
    cluster_risk_score: float | None  # 0..1
    label: ClusterLabel
    clustered_buy_share: float | None
    largest_cluster_buy_share: float | None
    methodology: str = (
        "Union-find over edges: (1) wallets whose first observed native funding came from the same "
        "source within a window; (2) direct native transfers between trading wallets; (3) wallet pairs "
        "whose buys landed within a tolerance of each other repeatedly; (4) wallets funded by the creator. "
        "Risk = buy-volume share held by multi-wallet clusters, weighted toward the largest cluster."
    )
    notes: list[str] = field(default_factory=list)

    def to_dict(self) -> dict:
        return {
            "cluster_risk_score": self.cluster_risk_score, "label": self.label.value,
            "clustered_buy_share": self.clustered_buy_share,
            "largest_cluster_buy_share": self.largest_cluster_buy_share,
            "clusters": [c.to_dict() for c in self.clusters if len(c.wallets) > 1],
            "methodology": self.methodology, "notes": self.notes,
        }


class _UF:
    def __init__(self) -> None:
        self.p: dict[str, str] = {}

    def find(self, x: str) -> str:
        self.p.setdefault(x, x)
        while self.p[x] != x:
            self.p[x] = self.p[self.p[x]]
            x = self.p[x]
        return x

    def union(self, a: str, b: str) -> None:
        ra, rb = self.find(a), self.find(b)
        if ra != rb:
            self.p[max(ra, rb)] = min(ra, rb)


# Exchanges and bridges fund thousands of unrelated wallets. Treat them as
# non-informative funders. Populate from a maintained address book.
DEFAULT_IGNORED_FUNDERS: frozenset[str] = frozenset()


def build_edges(swaps: Sequence[Swap], funding: Sequence[FundingTransfer], creator: str | None,
                shared_window_ms: int, sync_tol_ms: int, min_sync: int,
                ignored_funders: Iterable[str] = DEFAULT_IGNORED_FUNDERS) -> list[Edge]:
    traders = {s.wallet for s in swaps}
    ignored = set(ignored_funders)
    edges: list[Edge] = []

    # (1) shared first funder
    first_fund: dict[str, FundingTransfer] = {}
    for f in sorted(funding, key=lambda f: f.ts):
        if f.dst in traders and f.dst not in first_fund:
            first_fund[f.dst] = f
    by_src: dict[str, list[FundingTransfer]] = defaultdict(list)
    for f in first_fund.values():
        if f.src not in ignored:
            by_src[f.src].append(f)
    for src, fs in by_src.items():
        fs.sort(key=lambda f: f.ts)
        for x, y in zip(fs, fs[1:]):
            if y.ts - x.ts <= shared_window_ms:
                edges.append(Edge(x.dst, y.dst, "shared_funding",
                                  f"both first funded by {src} within {(y.ts - x.ts) / 1000:.0f}s",
                                  (x.tx_hash, y.tx_hash)))
        if creator and src == creator:
            for f in fs:
                edges.append(Edge(creator, f.dst, "creator_link", "first funded by creator", (f.tx_hash,)))

    # (2) direct transfers between wallets that both trade this token
    for f in funding:
        if f.src in traders and f.dst in traders and f.src != f.dst:
            edges.append(Edge(f.src, f.dst, "direct_transfer", f"native transfer {f.amount}", (f.tx_hash,)))

    # (3) repeatedly synchronized buys
    buys = sorted((s for s in swaps if s.side == Side.BUY), key=lambda s: s.ts)
    pair_hits: dict[tuple[str, str], list[str]] = defaultdict(list)
    j = 0
    for i, s in enumerate(buys):
        while buys[j].ts < s.ts - sync_tol_ms:
            j += 1
        for k in range(j, i):
            o = buys[k]
            if o.wallet != s.wallet:
                key = tuple(sorted((o.wallet, s.wallet)))
                pair_hits[key].append(s.tx_hash)
    for (a, b), txs in pair_hits.items():
        if len(txs) >= min_sync:
            edges.append(Edge(a, b, "synchronized_trades",
                              f"{len(txs)} buys within {sync_tol_ms} ms of each other", tuple(txs[:10])))
    return edges


def analyze(swaps: Sequence[Swap], funding: Sequence[FundingTransfer], creator: str | None, cfg: dict,
            ignored_funders: Iterable[str] = DEFAULT_IGNORED_FUNDERS) -> ClusterReport:
    edges = build_edges(swaps, funding, creator, cfg["shared_funding_window_ms"], cfg["sync_tolerance_ms"],
                        cfg["min_sync_repeats"], ignored_funders)
    uf = _UF()
    for s in swaps:
        uf.find(s.wallet)
    for e in edges:
        uf.union(e.a, e.b)
    members: dict[str, list[str]] = defaultdict(list)
    for w in list(uf.p):
        members[uf.find(w)].append(w)
    edge_by_root: dict[str, list[Edge]] = defaultdict(list)
    for e in edges:
        edge_by_root[uf.find(e.a)].append(e)

    clusters = {r: Cluster(r, sorted(ws), edge_by_root.get(r, []), contains_creator=bool(creator and creator in ws))
                for r, ws in members.items()}
    for s in swaps:
        c = clusters[uf.find(s.wallet)]
        if s.side == Side.BUY:
            c.buy_usd += s.quote_usd
        else:
            c.sell_usd += s.quote_usd
    total_buy = sum(c.buy_usd for c in clusters.values())
    cluster_of = {w: uf.find(w) for w in uf.p}
    multi = [c for c in clusters.values() if len(c.wallets) > 1]
    if total_buy <= 0:
        return ClusterReport(list(clusters.values()), cluster_of, None, ClusterLabel.INDEPENDENT, None, None,
                             notes=["no buy volume"])
    clustered = sum(c.buy_usd for c in multi) / total_buy
    largest = max((c.buy_usd for c in multi), default=0.0) / total_buy
    risk = min(1.0, 0.5 * clustered + 0.5 * largest * 1.5)
    kinds = {e.kind for c in multi for e in c.edges}
    if risk < 0.15:
        label = ClusterLabel.INDEPENDENT
    elif "synchronized_trades" in kinds and ("shared_funding" in kinds or "creator_link" in kinds) and risk >= 0.4:
        label = ClusterLabel.SUSPICIOUS_PATTERN
    elif "synchronized_trades" in kinds:
        label = ClusterLabel.HIGHLY_CORRELATED if risk >= 0.3 else ClusterLabel.COORDINATED_LOOKING
    elif "shared_funding" in kinds or "creator_link" in kinds:
        label = ClusterLabel.COORDINATED_LOOKING
    else:
        label = ClusterLabel.CONCENTRATED
    return ClusterReport(list(clusters.values()), cluster_of, risk, label, clustered, largest)
