"""Who is buying: breadth, novelty and independence of participants."""
from __future__ import annotations

from collections import defaultdict
from dataclasses import dataclass
from typing import Mapping, Sequence

from ..core import stats
from ..core.models import HolderSnapshot, Side, Swap
from ..core.values import DataStatus, Obs, missing, ok


@dataclass
class Participation:
    unique_buyers: Obs
    unique_sellers: Obs
    buyer_growth: Obs  # unique buyers now / median of prior windows
    new_wallets: Obs
    new_wallet_share: Obs
    returning_wallets: Obs
    new_wallet_velocity: Obs  # new wallets now / median new wallets in prior windows
    top_k_buy_share: Obs
    buy_hhi: Obs
    effective_buyers: Obs  # distinct clusters among buyers (cluster-collapsed count)
    independence_ratio: Obs  # effective_buyers / unique_buyers
    holders: Obs
    holder_growth: Obs  # relative change over the window
    top10_pct: Obs
    creator_pct: Obs
    large_holder_net_usd: Obs  # net buy (+) / sell (-) of the largest wallets in window
    creator_net_usd: Obs

    def to_dict(self) -> dict:
        return {k: v.to_dict() for k, v in self.__dict__.items()}


def compute(swaps: Sequence[Swap], holders: Sequence[HolderSnapshot], as_of: int, window_ms: int,
            baseline_windows: int, top_k: int, creator: str | None,
            cluster_of: Mapping[str, str] | None = None, flow_covered_from: int | None = None,
            independence_note: str | None = None) -> Participation:
    """``flow_covered_from``: earliest time from which the swap stream is known
    complete up to ``as_of`` (None = complete for all history, the synthetic
    case). Windows reaching before it report MISSING or INSUFFICIENT_HISTORY
    instead of counting unobserved minutes as zero buyers.
    ``independence_note``: when set, cluster collapsing ran on incomplete
    graph inputs, so the independence ratio is reported as UNVERIFIED."""
    start = as_of - window_ms
    cur = [s for s in swaps if start <= s.ts < as_of]
    first_seen: dict[str, int] = {}
    for s in swaps:
        if s.ts < as_of and s.wallet not in first_seen:
            first_seen[s.wallet] = s.ts

    def window_sets(lo: int, hi: int) -> tuple[set[str], set[str]]:
        buyers = {s.wallet for s in swaps if lo <= s.ts < hi and s.side == Side.BUY}
        new = {w for w in buyers if lo <= first_seen.get(w, -1) < hi}
        return buyers, new

    buyers, new = window_sets(start, as_of)
    sellers = {s.wallet for s in cur if s.side == Side.SELL}

    prior_b, prior_n = [], []
    for k in range(1, baseline_windows + 1):
        b, n = window_sets(start - k * window_ms, start - (k - 1) * window_ms)
        prior_b.append(len(b))
        prior_n.append(len(n))
    have_base = swaps and swaps[0].ts <= start - baseline_windows * window_ms
    base_reason = "token younger than participation baseline"
    if flow_covered_from is not None and flow_covered_from > start - baseline_windows * window_ms:
        have_base = False
        base_reason = "trade stream not observed for the whole participation baseline"
    window_observed = flow_covered_from is None or flow_covered_from <= start

    def ratio(now: int, prior: list[int]) -> Obs:
        if not have_base:
            return missing(base_reason, DataStatus.INSUFFICIENT_HISTORY)
        # Add-one smoothing keeps quiet baselines (median 0) finite and comparable.
        return ok((now + 1) / (stats.median(prior) + 1))

    buy_by_wallet: dict[str, float] = defaultdict(float)
    net_by_wallet: dict[str, float] = defaultdict(float)
    for s in cur:
        signed = s.quote_usd if s.side == Side.BUY else -s.quote_usd
        net_by_wallet[s.wallet] += signed
        if s.side == Side.BUY:
            buy_by_wallet[s.wallet] += s.quote_usd
    total_buy = sum(buy_by_wallet.values())
    ranked = sorted(buy_by_wallet.values(), reverse=True)

    # Largest wallets by estimated position across all history (token units).
    pos: dict[str, float] = defaultdict(float)
    for s in swaps:
        if s.ts < as_of:
            pos[s.wallet] += s.token_amount if s.side == Side.BUY else -s.token_amount
    large = {w for w, _ in sorted(pos.items(), key=lambda kv: kv[1], reverse=True)[:top_k]}

    if cluster_of is not None:
        eff = len({cluster_of.get(w, w) for w in buyers})
        eff_obs = ok(eff)
        indep = ok(eff / len(buyers)) if buyers else missing("no buyers")
    else:
        eff_obs = missing("cluster analysis not run")
        indep = missing("cluster analysis not run")

    if independence_note and indep.ok:
        indep = Obs(indep.value, DataStatus.UNVERIFIED, independence_note)
        eff_obs = Obs(eff_obs.value, DataStatus.UNVERIFIED, independence_note)

    h_now = [h for h in holders if h.ts < as_of]
    h_prev = [h for h in h_now if h.ts <= start]
    latest = h_now[-1] if h_now else None
    if not window_observed:
        m = missing("trade stream not observed for the whole current window")
        hold = dict(holders=ok(latest.holders) if latest else missing("no holder snapshots"),
                    holder_growth=(ok(latest.holders / h_prev[-1].holders - 1) if latest and h_prev and h_prev[-1].holders > 0
                                   else missing("no holder snapshot at window start")),
                    top10_pct=ok(latest.top10_pct) if latest else missing("no holder snapshots"),
                    creator_pct=(ok(latest.creator_pct) if latest and latest.creator_pct is not None
                                 else missing("creator holdings unknown")))
        return Participation(m, m, m, m, m, m, m, m, m, m, m, large_holder_net_usd=m, creator_net_usd=m, **hold)
    return Participation(
        unique_buyers=ok(len(buyers)),
        unique_sellers=ok(len(sellers)),
        buyer_growth=ratio(len(buyers), prior_b),
        new_wallets=ok(len(new)),
        new_wallet_share=ok(len(new) / len(buyers)) if buyers else missing("no buyers"),
        returning_wallets=ok(len(buyers - new)),
        new_wallet_velocity=ratio(len(new), prior_n),
        top_k_buy_share=ok(sum(ranked[:top_k]) / total_buy) if total_buy > 0 else missing("no buy volume"),
        buy_hhi=ok(stats.hhi(ranked)) if total_buy > 0 else missing("no buy volume"),
        effective_buyers=eff_obs,
        independence_ratio=indep,
        holders=ok(latest.holders) if latest else missing("no holder snapshots"),
        holder_growth=(ok(latest.holders / h_prev[-1].holders - 1) if latest and h_prev and h_prev[-1].holders > 0
                       else missing("no holder snapshot at window start")),
        top10_pct=ok(latest.top10_pct) if latest else missing("no holder snapshots"),
        creator_pct=(ok(latest.creator_pct) if latest and latest.creator_pct is not None
                     else missing("creator holdings unknown")),
        large_holder_net_usd=ok(sum(net_by_wallet[w] for w in large if w in net_by_wallet)),
        creator_net_usd=(ok(net_by_wallet.get(creator, 0.0)) if creator else missing("creator unknown")),
    )
