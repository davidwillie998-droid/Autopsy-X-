"""Stage orchestration.

DATA -> QUALITY -> BARS/MARKET STATE -> MOVE -> PARTICIPATION -> LIQUIDITY ->
CLUSTERS -> MANIPULATION -> NEWS -> SOCIAL -> REGIME -> EXHAUSTION ->
(cross-token) NARRATIVE + LEAD/LAG -> MOVE QUALITY -> SIGNAL

Each stage is a pure function of the point-in-time view and the config. The
pipeline only wires outputs to inputs.
"""
from __future__ import annotations

import logging
import math
from dataclasses import dataclass, field

from .assessment import Assessment
from .core.config import Config
from .core.failure import FailureMode
from .core.logs import event, timed
from .core.models import TokenMeta
from .core.values import DataStatus, Obs, missing, ok
from .detection import move as move_mod
from .detection import move_quality as mq_mod
from .features import bars as bars_mod
from .features import liquidity as liq_mod
from .features import market as market_mod
from .features import participation as part_mod
from .manipulation import detectors as manip_mod
from .narrative import engine as narr_mod
from .narrative import leadlag as ll_mod
from .news import catalyst as news_mod
from .onchain import clusters as cluster_mod
from .providers.store import PointInTimeView
from .quality import checks as quality_mod
from .regime import classifier as regime_mod
from .signals import entry as entry_mod
from .signals import exhaustion as exh_mod
from .social import attention as social_mod

log = logging.getLogger("autopsyx.pipeline")


@dataclass(frozen=True)
class Capabilities:
    """Which input classes the dataset actually contains. A False entry makes
    every consumer of that input report it as unavailable instead of treating
    the empty list as "checked, nothing found". Defaults describe the complete
    synthetic scenarios."""

    funding: bool = True  # native funding transfers (cluster shared-funding edges, fresh-wallet detector)
    liquidity_events: bool = True  # LP add/remove events
    news: bool = True
    social: bool = True
    creator: bool = True  # creator/deployer identity

    @classmethod
    def from_dict(cls, d: dict) -> "Capabilities":
        return cls(**{k: bool(v) for k, v in d.items() if k in cls.__dataclass_fields__})


FULL = Capabilities()


@dataclass
class ScanResult:
    as_of: int
    assessments: dict[str, Assessment]
    signals: dict[str, entry_mod.Signal]
    narratives: dict[str, narr_mod.NarrativeState]
    lead_lag: list[ll_mod.LeadLag] = field(default_factory=list)
    symbol_collisions: dict[str, list[str]] = field(default_factory=dict)


def assess_token(view: PointInTimeView, token: TokenMeta, cfg: Config, social_available: bool = True,
                 caps: Capabilities = FULL) -> Assessment:
    as_of = view.as_of
    key = token.ref.key
    interval = cfg.section("bars")["interval_ms"]
    mcfg = cfg.section("move")
    dq = cfg.section("data_quality")
    social_available = social_available and caps.social

    raw_swaps = view.swaps(key)
    snaps = view.pool_snapshots(key)
    swaps, qrep = quality_mod.run(key, raw_swaps, snaps, as_of, dq)

    lookback = (mcfg["baseline_bars"] + max(mcfg["windows"]) + 1) * interval
    pbars = view.provider_bars(key)
    flow_from: int | None = None  # None = swap stream complete for all history (synthetic data)
    part_as_of = as_of
    if pbars:
        # Real-data path: price/volume from provider OHLCV, order flow from swaps where covered.
        bar_cov = view.coverage(key, "bars")
        trade_cov = view.coverage(key, "trades")
        bar_end = max((c.end_ts for c in bar_cov), default=None)
        if bar_end is None:
            bars = []
            qrep.flag(FailureMode.NO_DATA, "provider bars present but no bar coverage claim")
        else:
            end = min(as_of, bar_end)
            end -= end % interval
            bars = bars_mod.build_bars_from_provider(pbars, swaps, bar_cov, trade_cov, interval,
                                                     max(end - lookback, pbars[0].ts), end)
            if as_of - end > dq["max_price_age_ms"]:
                qrep.flag(FailureMode.STALE_DATA, f"closed-bar coverage ends {as_of - end} ms before as_of")
        tcov = bars_mod.covered_intervals(trade_cov)
        t_end = max((b for _, b in tcov), default=None)
        if t_end is None:
            flow_from, part_as_of = as_of, as_of  # nothing observed: every flow window is unobserved
        else:
            part_as_of = min(as_of, t_end)
            flow_from = bars_mod.contiguous_from(tcov, part_as_of)
            if as_of - part_as_of > dq["max_price_age_ms"]:
                qrep.flag(FailureMode.STALE_DATA, f"trade coverage ends {as_of - part_as_of} ms before as_of")
    else:
        bars = bars_mod.build_bars(swaps, interval, max(as_of - lookback, swaps[0].ts if swaps else as_of), as_of)
        if bars and bars[-1].ts + interval > as_of:
            bars = bars[:-1]  # drop the still-forming bar: only closed bars are observations

    pools = view.pools(key)
    liq_events = view.liquidity_events(key)
    lcfg = cfg.section("liquidity")
    prio = cfg.raw.get("data_sources", {}).get("liquidity_source_priority")
    pre_liq = liq_mod.compute(snaps, liq_events, pools, as_of, lcfg["window_bars"] * interval,
                              lcfg["reference_trade_usd"], missing("pending"), prio, dq["max_price_age_ms"])
    market = market_mod.compute(bars, mcfg, pre_liq.liquidity_usd, token.total_supply) if bars else \
        market_mod.MarketState(as_of=as_of, price=missing("no bars"))
    liq = liq_mod.compute(snaps, liq_events, pools, as_of, lcfg["window_bars"] * interval,
                          lcfg["reference_trade_usd"], market.market_cap, prio, dq["max_price_age_ms"])
    if liq.liquidity_usd.status == DataStatus.STALE:
        qrep.flag(FailureMode.STALE_DATA, liq.liquidity_usd.reason)
    if liq.liquidity_usd.ok and liq.liquidity_usd.value < cfg.section("risk")["min_liquidity_usd"]:
        qrep.flag(FailureMode.LOW_LIQUIDITY, f"${liq.liquidity_usd.value:,.0f} below minimum")
    if liq.est_slippage.ok and liq.est_slippage.value > cfg.section("risk")["max_slippage"]:
        qrep.flag(FailureMode.HIGH_SLIPPAGE, f"{liq.est_slippage.value:.2%} on reference trade")
    if market.sigma_1bar.status == DataStatus.INSUFFICIENT_HISTORY:
        qrep.failures.add(FailureMode.INSUFFICIENT_HISTORY)

    mv = move_mod.classify(market, bars, mcfg) if bars else move_mod.MoveAssessment(
        move_mod.MoveClass.UNCLASSIFIED, 0, None, None, {}, None, None, None, False, "no bars")
    if mv.abnormality is not None and mv.abnormality >= mcfg["thresholds"]["extreme"] * 1.5:
        qrep.failures.add(FailureMode.EXTREME_VOLATILITY)

    ccfg = cfg.section("clusters")
    wallets = {s.wallet for s in swaps}
    funding = [f for f in view.funding() if f.dst in wallets or f.src in wallets]
    clusters = cluster_mod.analyze(swaps, funding, token.creator, ccfg)
    if not caps.funding:
        clusters.notes.append("funding transfers unavailable: shared-funding and creator-link edges not evaluated")

    pcfg = cfg.section("participation")
    part = part_mod.compute([s for s in swaps if s.ts < part_as_of], view.holder_snapshots(key), part_as_of,
                            pcfg["window_bars"] * interval, pcfg["baseline_windows"], pcfg["top_k"], token.creator,
                            clusters.cluster_of, flow_covered_from=flow_from,
                            independence_note=None if caps.funding else
                            "cluster graph built without funding transfers; independence overstated")

    scfg = cfg.section("social")
    social = social_mod.compute(view.social(key), as_of, scfg, social_available)
    extra = []
    if social.artificial_attention_score.ok and social.artificial_attention_score.value >= 0.6:
        extra.append(manip_mod.Flag(
            kind="social_engagement_anomaly", confidence=social.artificial_attention_score.value * 0.6,
            evidence={"duplicate_ratio": social.duplicate_ratio.value, "author_hhi": social.author_hhi.value,
                      "mentions": social.mentions.value, "effective_authors": social.effective_authors.value},
            wallets=[], timestamps=[], transactions=[],
            methodology="Composite of near-duplicate share, repost share, author concentration, new-account "
                        "share, and the gap between raw mentions and effective independent authors.",
            alternative_explanation="Organised but genuine communities (raids, fan campaigns) also post "
                                    "templated content; check on-chain participation before discounting.",
        ))
    win_ms = pcfg["window_bars"] * interval * pcfg["baseline_windows"]
    recent_swaps = [s for s in swaps if s.ts >= as_of - win_ms]
    flow_ok = flow_from is None or flow_from <= part_as_of - win_ms
    manip = manip_mod.run_all(swaps=recent_swaps, funding=funding, events=liq_events, pools=pools,
                              creator=token.creator, total_supply=token.total_supply, clusters=clusters,
                              cfg=cfg.section("manipulation"), fresh_ms=ccfg["fresh_wallet_ms"], extra_flags=extra,
                              available={"flow": flow_ok, "funding": caps.funding,
                                         "liquidity_events": caps.liquidity_events,
                                         "creator": caps.creator and token.creator is not None})

    cat = news_mod.assess(key, mv.onset_ts, mv.direction, view.news(), cfg.section("news"))
    if not caps.news:
        cat.reason = "news provider unavailable for this dataset; catalyst unknown, not absent"
    rg = regime_mod.classify(bars, market, part, liq, mv, cfg.section("regime"), mcfg) if bars else \
        regime_mod.RegimeAssessment(regime_mod.Regime.UNKNOWN, reasons=["no bars"])
    exh = exh_mod.assess(bars, market, part, liq, mv, rg, social, cfg.section("exhaustion"),
                         cfg.section("regime")["parabolic_z"], cfg.section("signal")["max_top10_pct"])

    venues = _cross_venue(snaps, as_of, interval * 15)
    created = min([p.created_ts for p in pools] + ([token.launch_ts] if token.launch_ts else []), default=None)
    early = cfg.raw.get("lifecycle", {}).get("early_life_ms", 86_400_000)
    if created is None:
        lifecycle = "UNKNOWN_AGE"
    elif as_of - created < early:
        lifecycle = "EARLY_LIFE"
    else:
        lifecycle = "ESTABLISHED"
    return Assessment(token=token, as_of=as_of, quality=qrep, bars=bars, market=market, move=mv,
                      participation=part, liquidity=liq, clusters=clusters, manipulation=manip, catalyst=cat,
                      social=social, regime=rg, exhaustion=exh, narratives=narr_mod.assign(token),
                      cross_venue=venues, lifecycle=lifecycle, token_age_ms=None if created is None else as_of - created)


def _cross_venue(snaps, as_of: int, window_ms: int) -> Obs:
    """Fraction of pools whose price moved in the same direction as the majority over the window."""
    by_pool: dict[str, list] = {}
    for s in snaps:
        if as_of - window_ms <= s.ts < as_of:
            by_pool.setdefault(s.pool, []).append(s)
    moves = []
    for ss in by_pool.values():
        if len(ss) >= 2 and ss[0].price_usd > 0:
            moves.append(ss[-1].price_usd / ss[0].price_usd - 1)
    if len(moves) < 2:
        return missing("fewer than two venues with price history")
    up = sum(1 for m in moves if m > 0)
    return ok(max(up, len(moves) - up) / len(moves))


def _member(a: Assessment, breadth_class: str) -> narr_mod.MemberSnapshot:
    w15 = a.market.windows.get(15)
    w60 = a.market.windows.get(60)
    return narr_mod.MemberSnapshot(
        token_key=a.key,
        moving_up=a.move.direction > 0 and move_mod.at_least(a.move.move_class, breadth_class),
        volume_z=w15.volume_z.or_none() if w15 else None,
        buyer_growth=a.participation.buyer_growth.or_none(),
        social_velocity=a.social.mention_velocity.or_none(),
        news_count=len(a.catalyst.candidates),
        is_new_launch=a.token.launch_ts is not None and a.as_of - a.token.launch_ts < 86_400_000,
        market_cap=a.market.market_cap.or_none(),
        volume_usd=w60.volume_usd.or_none() if w60 else None,
    )


def scan(view: PointInTimeView, cfg: Config, prior: ScanResult | None = None,
         social_available: bool = True, caps: Capabilities = FULL) -> ScanResult:
    tokens = view.tokens()
    with timed(log, "per_token"):
        assessments = {t.ref.key: assess_token(view, t, cfg, social_available, caps) for t in tokens}

    # Narrative stage (cross-token)
    ncfg = cfg.section("narrative")
    groups: dict[str, list[str]] = {}
    for k, a in assessments.items():
        for n in a.narratives:
            groups.setdefault(n, []).append(k)
    narratives = {}
    for n, keys in groups.items():
        now = [_member(assessments[k], ncfg["breadth_move_class"]) for k in keys]
        prev = [_member(prior.assessments[k], ncfg["breadth_move_class"]) for k in keys
                if prior and k in prior.assessments]
        narratives[n] = narr_mod.evaluate(n, now, prev, ncfg["min_members"])

    # Lead/lag over aligned 1-bar returns
    llcfg = cfg.section("leadlag")
    series = {}
    n_bars = 120
    for k, a in assessments.items():
        cl = [b.close for b in a.bars[-n_bars - 1:]]
        if len(cl) == n_bars + 1 and all(c and c > 0 for c in cl):
            series[k] = [math.log(cl[i + 1] / cl[i]) for i in range(n_bars)]
    moving = {k for k, a in assessments.items() if a.move.direction > 0 and
              move_mod.at_least(a.move.move_class, "UNUSUAL")}
    roles, links = ll_mod.analyze(series, moving, llcfg["max_lag_bars"], llcfg["min_corr"],
                                  llcfg["min_lag_advantage"]) if len(series) >= 2 \
        else ({}, [])

    mcfg = cfg.section("move")
    signals = {}
    for k, a in assessments.items():
        states = [narratives[n] for n in a.narratives if n in narratives and narratives[n].breadth is not None
                  and n != "meme"]
        a.narrative_phases = {s.narrative: s.phase.value for s in states}
        a.narrative_breadth = ok(max(s.breadth for s in states)) if states else missing("no narrative with enough members")
        a.role = roles.get(k, ll_mod.Role.ISOLATED).value
        d = a.move.driving_window
        drive = a.market.windows.get(d) if d else None
        w15 = a.market.windows.get(15)
        a.move_quality = mq_mod.score(
            price_z=drive.z if drive else missing("no driving window"),
            volume_z=w15.volume_z if w15 else missing("no 15m window"),
            buyer_growth=a.participation.buyer_growth, independence=a.participation.independence_ratio,
            liquidity_change=a.liquidity.liquidity_change, breadth=a.narrative_breadth,
            catalyst=ok(a.catalyst.score) if a.catalyst.primary_event else missing("no catalyst identified"),
            cross_venue=a.cross_venue, manipulation=ok(a.manipulation.score),
            concentration=a.participation.top_k_buy_share, slippage=a.liquidity.est_slippage,
            cfg=cfg.section("move_quality"), max_slippage=cfg.section("risk")["max_slippage"],
            significant_z=mcfg["thresholds"]["significant"],
        )
        signals[k] = entry_mod.generate(a, cfg.section("signal"), cfg.section("risk"), mcfg)
    event(log, "scan_done", as_of=view.as_of, tokens=len(tokens), config=cfg.fingerprint(),
          signals={k: s.type.value for k, s in signals.items() if s.type != entry_mod.SignalType.NO_SIGNAL})
    return ScanResult(view.as_of, assessments, signals, narratives, links,
                      quality_mod.symbol_collisions(tokens))
