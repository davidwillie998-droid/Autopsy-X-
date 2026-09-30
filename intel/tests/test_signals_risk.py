from autopsyx.core.failure import FailureMode
from autopsyx.pipeline import scan
from autopsyx.risk import engine as risk
from autopsyx.signals import exit as exit_mod
from autopsyx.signals.entry import SignalType
from autopsyx.sim import generator

from conftest import key

ORGANIC, WASH, RUG, QUIET, FOLLOWER = (key(a) for a in ("PEPEaddr", "FROGaddr", "HAMSaddr", "CATZaddr", "DOGEaddr"))


def test_signal_contains_required_fields(result):
    s = result.signals[ORGANIC].to_dict()
    for f in ("token", "chain", "timestamp", "current_price", "move_percent", "volume_acceleration", "liquidity",
              "wallet_growth", "news_catalyst", "narrative", "manipulation_risk", "regime", "signal_score",
              "confidence", "invalidation", "risk_flags"):
        assert f in s


def test_organic_continuation_fires(result):
    assert result.signals[ORGANIC].type == SignalType.HIGH_CONVICTION_CONTINUATION


def test_manufactured_move_vetoed(result):
    s = result.signals[WASH]
    assert s.type == SignalType.NO_SIGNAL
    assert any("low_manipulation" in b for b in s.blocked_by)


def test_quiet_token_silent(result):
    assert result.signals[QUIET].type == SignalType.NO_SIGNAL


def test_follower_needs_own_confirmation(result):
    names = [c.name for c in result.signals[FOLLOWER].conditions]
    assert "follower_independent_confirmation" in names


def test_stale_data_means_no_signal(store, cfg, end_ts):
    res = scan(store.view(end_ts + 30 * 60_000), cfg)  # nothing new for 30 minutes
    s = res.signals[ORGANIC]
    assert s.type == SignalType.NO_SIGNAL and FailureMode.STALE_DATA.value in s.blocked_by


def test_missing_social_does_not_fabricate(store, cfg, end_ts):
    res = scan(store.view(end_ts), cfg, social_available=False)
    a = res.assessments[ORGANIC]
    assert a.social.mentions.value is None and a.social.mentions.status.value == "MISSING"
    assert a.social.artificial_attention_score.value is None
    assert not any(f.kind == "social_engagement_anomaly" for f in a.manipulation.flags)


def test_rug_triggers_emergency_exit(store, cfg):
    spec = generator.DEFAULT_SCENARIOS[2]
    t_in = generator.T0 + (spec.onset_bar - 5) * generator.MIN
    t_after = generator.T0 + (spec.onset_bar + 3) * generator.MIN
    before = scan(store.view(t_in), cfg).assessments[RUG]
    pos = exit_mod.Position(RUG, t_in, before.market.price.value, before.liquidity.liquidity_usd.value, 1000, None)
    after = scan(store.view(t_after), cfg).assessments[RUG]
    d = exit_mod.decide(pos, after, cfg.section("exit"))
    assert d.action == exit_mod.ExitAction.EMERGENCY_EXIT
    assert any("liquidity down" in r for r in d.reasons)


def test_hold_when_nothing_deteriorates(result, cfg):
    a = result.assessments[ORGANIC]
    pos = exit_mod.Position(ORGANIC, a.as_of, a.market.price.value * 0.9, a.liquidity.liquidity_usd.value, 1, None)
    assert exit_mod.decide(pos, a, cfg.section("exit")).action in (exit_mod.ExitAction.HOLD, exit_mod.ExitAction.REDUCE)


def _prop(liq=1_000_000.0, price=1.0, inv=0.8):
    return risk.TradeProposal("solana:t", "solana", ["ai"], price, inv, liq, 30.0, "cpmm")


def test_risk_sizes_to_budget_and_pool_share(cfg):
    rc = cfg.section("risk")
    d = risk.evaluate(_prop(), risk.PortfolioState(10_000.0), rc)
    assert d.approved
    loss_at_stop = d.notional_usd * (0.2 + rc["max_slippage"] * rc["exit_slippage_multiplier"])
    assert loss_at_stop <= rc["max_risk_per_position"] * 10_000 + 1e-6
    assert d.notional_usd <= rc["max_pool_share"] * 1_000_000


def test_risk_refuses_low_liquidity_and_loss_limits(cfg):
    rc = cfg.section("risk")
    assert not risk.evaluate(_prop(liq=10_000), risk.PortfolioState(10_000.0), rc).approved
    pf = risk.PortfolioState(10_000.0, realized_pnl_today_usd=-500)
    assert not risk.evaluate(_prop(), pf, rc).approved
    pf = risk.PortfolioState(10_000.0, consecutive_losses=rc["max_consecutive_losses"])
    assert not risk.evaluate(_prop(), pf, rc).approved
    assert not risk.evaluate(_prop(inv=None), risk.PortfolioState(10_000.0), rc).approved


def test_risk_narrative_exposure_cap(cfg):
    rc = cfg.section("risk")
    pf = risk.PortfolioState(10_000.0, [risk.OpenPosition("solana:x", "solana", ["ai"], 1_000.0)])
    d = risk.evaluate(_prop(), pf, rc)
    assert not d.approved or d.limits["narrative_room"] == 0.0
