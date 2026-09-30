"""Adversarial point-in-time tests on the provider (real-data) path, plus
missing-data, stale-data and conflict behaviour."""
import json

import pytest

from autopsyx.core.failure import FailureMode
from autopsyx.core.models import Coverage, PoolSnapshot, ProviderBar, Side, SocialPost, Swap
from autopsyx.core.values import DataStatus
from autopsyx.data.normalize import PHASE2_CAPABILITIES as CAPS
from autopsyx.pipeline import scan
from autopsyx.providers.store import EventStore
from autopsyx.ranking import all_rankings
from autopsyx.risk import engine as risk
from autopsyx.signals import exit as exit_mod
from autopsyx.signals.entry import SignalType

from phase2_fakes import KEY, LAG, MIN, POOL, T0, TOKEN, as_of_after, real_path_records, real_store, wallet

T = as_of_after(660)  # mid-move: every stage has something to say


def full_output(store, cfg, t=T, caps=CAPS):
    """Everything downstream of the view: assessment, signal, rankings, exit decision, risk decision."""
    res = scan(store.view(t), cfg, caps=caps)
    a, s = res.assessments[KEY], res.signals[KEY]
    pos = exit_mod.Position(KEY, t, 1e-4, 300_000.0, 1.0, 5e-5)
    prop = risk.TradeProposal(KEY, "solana", a.narratives, a.market.price.value or 0.0, 5e-5,
                              a.liquidity.liquidity_usd.value, 25.0, a.liquidity.amm_model)
    return json.dumps({
        "assessment": a.to_dict(), "signal": s.to_dict(), "rankings": all_rankings(res.assessments),
        "exit": exit_mod.decide(pos, a, cfg.section("exit")).to_dict(),
        "risk": risk.evaluate(prop, risk.PortfolioState(10_000.0), cfg.section("risk")).to_dict(),
    }, sort_keys=True, default=str)


def with_extra(extra):
    s = real_store()
    s.extend(extra)
    return s


def test_A_future_append_leaves_past_assessment_byte_identical(cfg):
    before = full_output(real_store(bars=700), cfg)
    grown = real_store(bars=900)  # 200 more minutes appended after T
    assert full_output(grown, cfg) == before


def test_B_late_arriving_observation_is_invisible(cfg):
    base = full_output(real_store(), cfg)
    t_event = T - 10 * MIN
    late = [
        Swap("solana", "late", 0, t_event, T + 1, t_event // 400, POOL, TOKEN, wallet(999_999), Side.BUY,
             1e9, 250_000.0, 2.5e-4, "geckoterminal", "late"),
        ProviderBar("solana", POOL, TOKEN, t_event - t_event % MIN, MIN, T + 1, 1e-4, 9e-4, 1e-4, 9e-4, 5e6,
                    "geckoterminal", "late"),
        PoolSnapshot("solana", POOL, TOKEN, t_event, T + 1, 1.0, 9e-4, "geckoterminal", "late"),
    ]
    assert full_output(with_extra(late), cfg) == base
    # ...and it does become visible once available
    later = scan(with_extra(late).view(T + 2), cfg, caps=CAPS)
    assert any(s.tx_hash == "late" for s in with_extra(late).view(T + 2).swaps(KEY))
    assert later.assessments[KEY].as_of == T + 2


@pytest.mark.parametrize("stage", ["move", "manipulation", "regime", "exhaustion", "signal", "exit", "risk", "rankings"])
def test_C_future_transaction_influences_no_stage(cfg, stage):
    base = json.loads(full_output(real_store(), cfg))
    t_future = T + 5 * MIN
    dump = [Swap("solana", f"dump{i}", 0, t_future + i, t_future + i + LAG, (t_future + i) // 400, POOL, TOKEN,
                 wallet(7), Side.SELL, 1e10, 900_000.0, 1e-6, "geckoterminal", "future") for i in range(20)]
    dump.append(Coverage("solana", TOKEN, POOL, "trades", t_future, t_future + MIN, t_future + LAG,
                         "geckoterminal", "future"))
    after = json.loads(full_output(with_extra(dump), cfg))
    pick = {
        "move": lambda d: d["assessment"]["move"], "manipulation": lambda d: d["assessment"]["manipulation"],
        "regime": lambda d: d["assessment"]["regime"], "exhaustion": lambda d: d["assessment"]["exhaustion"],
        "signal": lambda d: d["signal"], "exit": lambda d: d["exit"], "risk": lambda d: d["risk"],
        "rankings": lambda d: d["rankings"],
    }[stage]
    assert pick(after) == pick(base)


def test_D_future_social_posts_cannot_alter_past_assessment(cfg):
    from autopsyx.pipeline import Capabilities
    caps = Capabilities(funding=False, liquidity_events=False, news=False, social=True, creator=True)
    past = [SocialPost(f"p{i}", "x", T - 30 * MIN + i * 1000, T - 30 * MIN + i * 1000 + 5_000, f"a{i}", None, 100,
                       f"stonk post {i}", (KEY,)) for i in range(20)]
    future = [SocialPost(f"f{i}", "x", T + i, T + i + 5_000, "bot", None, 1, "stonk to the moon", (KEY,))
              for i in range(500)]
    late_seen = [SocialPost(f"l{i}", "x", T - 60_000, T + 1, "bot", None, 1, "late copy", (KEY,)) for i in range(500)]
    base = full_output(with_extra(past), cfg, caps=caps)
    assert full_output(with_extra(past + future + late_seen), cfg, caps=caps) == base


# ------------------------------------------------------------------------ missing data ----
def test_no_trade_coverage_means_flow_missing_and_no_signal(cfg):
    s = real_store(trades_from=10_000)  # trades never observed
    res = scan(s.view(T), cfg, caps=CAPS)
    a, sig = res.assessments[KEY], res.signals[KEY]
    assert a.participation.unique_buyers.value is None
    assert a.participation.unique_buyers.status == DataStatus.MISSING
    assert a.market.windows[15].buy_sell_imbalance.value is None
    assert a.market.windows[15].trades_z.value is None
    assert "wash_trading" in a.manipulation.detectors_unavailable
    assert "wash_trading" not in a.manipulation.detectors_run
    assert sig.type == SignalType.NO_SIGNAL
    assert any("low_manipulation" in b for b in sig.blocked_by)


def test_partial_trade_history_is_insufficient_not_zero(cfg):
    s = real_store(trades_from=640)  # trades observed only for the last ~20 minutes
    a = scan(s.view(T), cfg, caps=CAPS).assessments[KEY]
    assert a.participation.buyer_growth.status == DataStatus.INSUFFICIENT_HISTORY
    assert a.participation.unique_buyers.ok  # the current window itself was observed


def test_unavailable_inputs_are_labelled_not_treated_as_clean(cfg):
    a = scan(real_store().view(T), cfg, caps=CAPS).assessments[KEY]
    assert a.participation.independence_ratio.status == DataStatus.UNVERIFIED
    assert {"fresh_wallet_burst", "liquidity_single_provider", "creator_distribution"} <= set(a.manipulation.detectors_unavailable)
    assert "news provider unavailable" in a.catalyst.reason
    assert a.social.mentions.value is None
    assert any("funding" in n for n in a.clusters.notes)


def test_missing_creator_holdings_block_signal(cfg):
    sig = scan(real_store().view(T), cfg, caps=CAPS).signals[KEY]
    assert sig.type == SignalType.NO_SIGNAL
    assert "critical input missing: creator_concentration_ok" in sig.blocked_by


def test_missing_candles_outside_coverage_are_incomplete(cfg):
    recs = [r for r in real_path_records() if not (isinstance(r, (ProviderBar, Coverage)) and r.kind == "bars"
                                                    if isinstance(r, Coverage) else
                                                    isinstance(r, ProviderBar) and 600 <= (r.ts - T0) // MIN < 610)]
    # drop bar coverage claims too, then re-add coverage that stops before the hole
    recs = [r for r in recs if not (isinstance(r, Coverage) and r.kind == "bars")]
    recs.append(Coverage("solana", TOKEN, POOL, "bars", T0, T0 + 600 * MIN, T0 + 601 * MIN + LAG, "geckoterminal", "c"))
    recs.append(Coverage("solana", TOKEN, POOL, "bars", T0 + 610 * MIN, T0 + 661 * MIN, T - 1, "geckoterminal", "c"))
    s = EventStore()
    s.extend(recs)
    a = scan(s.view(T), cfg, caps=CAPS).assessments[KEY]
    hole = [b for b in a.bars if T0 + 600 * MIN <= b.ts < T0 + 610 * MIN]
    assert hole and not any(b.complete for b in hole)
    assert a.market.windows[60].ret.value is None  # 60-bar window spans the hole


def test_stale_coverage_blocks_signal(cfg):
    s = real_store(bars=661)
    t = as_of_after(660) + 10 * MIN  # nothing polled for ten minutes
    res = scan(s.view(t), cfg, caps=CAPS)
    assert FailureMode.STALE_DATA in res.assessments[KEY].failures
    assert res.signals[KEY].type == SignalType.NO_SIGNAL


def test_stale_liquidity_is_flagged(cfg):
    recs = [r for r in real_path_records() if not isinstance(r, PoolSnapshot) or (r.ts - T0) // MIN < 500]
    s = EventStore()
    s.extend(recs)
    a = scan(s.view(T), cfg, caps=CAPS).assessments[KEY]
    # latest liquidity is hours old: the change is unobserved (not 0.0) and the level is not "healthy"
    assert a.liquidity.liquidity_change.value is None or a.liquidity.liquidity_change.status == DataStatus.MISSING
    assert a.liquidity.liquidity_usd.status == DataStatus.STALE
    assert FailureMode.STALE_DATA in a.failures


def test_cross_source_price_conflict(cfg):
    s = real_store(ds_price_skew=0.2)  # DexScreener 20% away from GeckoTerminal
    res = scan(s.view(T), cfg, caps=CAPS)
    assert FailureMode.CONFLICTING_DATA in res.assessments[KEY].failures
    assert FailureMode.CONFLICTING_DATA.value in res.signals[KEY].blocked_by


def test_liquidity_level_from_one_source_only(cfg):
    a = scan(real_store().view(T), cfg, caps=CAPS).assessments[KEY]
    # DexScreener reports 10% more liquidity; mixing sources would fake a +10% change
    assert abs(a.liquidity.liquidity_change.value) < 0.1


def test_early_life_label(cfg):
    from autopsyx.core.models import PoolInfo, TokenMeta, TokenRef
    recs = []
    for r in real_path_records():
        if isinstance(r, TokenMeta):
            r = TokenMeta(r.ref, r.symbol, r.name, T - 3_600_000, None, 1e9, r.seen_ts, source=r.source, raw_id=r.raw_id)
        if isinstance(r, PoolInfo):
            r = PoolInfo(r.chain, r.pool, r.token, r.venue, T - 3_600_000, r.seen_ts, r.amm_model, r.fee_bps, r.source, r.raw_id)
        recs.append(r)
    s = EventStore()
    s.extend(recs)
    a = scan(s.view(T), cfg, caps=CAPS).assessments[KEY]
    assert a.lifecycle == "EARLY_LIFE" and a.token_age_ms == 3_600_000
