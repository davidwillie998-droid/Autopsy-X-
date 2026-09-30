"""Replay, leakage, backtest, journal and model-validation tests."""
import json
import random

from autopsyx.alerts import engine as alerts
from autopsyx.backtest import engine as bt
from autopsyx.backtest import event_study
from autopsyx.backtest.metrics import max_drawdown, worst_sequence
from autopsyx.features import registry
from autopsyx.journal.journal import Journal, Outcome, TradeOutcome, label
from autopsyx.pipeline import scan
from autopsyx.providers.store import EventStore
from autopsyx.ranking import RANKINGS, all_rankings
from autopsyx.research.models import Logistic, Sample, evaluate_walk_forward, purged_walk_forward
from autopsyx.sim import generator

from conftest import key

ORGANIC = key("PEPEaddr")


def _strip(d):
    return json.dumps(d, sort_keys=True, default=str)


def test_no_lookahead_future_records_do_not_change_past_assessment(cfg):
    """Assessment at t must be identical whether or not the store holds data after t."""
    recs = generator.generate()
    t = generator.T0 + 560 * generator.MIN
    full = EventStore()
    full.extend(recs)
    past = EventStore()
    past.extend(r for r in recs if r.seen_ts <= t)
    a = scan(full.view(t), cfg).assessments[ORGANIC].to_dict()
    b = scan(past.view(t), cfg).assessments[ORGANIC].to_dict()
    assert _strip(a) == _strip(b)


def test_replay_is_deterministic(cfg):
    a = scan(generator.build_store().view(generator.end_ts()), cfg)
    b = scan(generator.build_store().view(generator.end_ts()), cfg)
    assert _strip({k: v.to_dict() for k, v in a.signals.items()}) == _strip({k: v.to_dict() for k, v in b.signals.items()})


def test_rankings_are_separate(result):
    r = all_rankings(result.assessments)
    assert set(r) == set(RANKINGS)
    assert r["HIGHEST_MANIPULATION_RISK"][0]["token"] in (key("FROGaddr"), key("HAMSaddr"))


def test_alerts_carry_evidence(result):
    al = alerts.token_alerts(result.assessments[ORGANIC])
    kinds = {a.kind for a in al}
    assert alerts.AlertKind.BREAKING_MOVE in kinds and alerts.AlertKind.NEWS_CATALYST in kinds
    assert all(a.evidence for a in al)


def test_timeline_is_chronological_and_point_in_time(store, result, end_ts):
    tl = alerts.raw_timeline(store.view(end_ts), result.assessments[ORGANIC])
    ts = [t for t, _ in tl]
    assert ts == sorted(ts) and all(t <= end_ts for t in ts)
    assert any("News published" in s for _, s in tl)


def test_backtest_runs_and_reports_tail_metrics(store, cfg):
    start = generator.T0 + 520 * generator.MIN
    res = bt.run(store, cfg, start, generator.end_ts() - 5 * generator.MIN, step_ms=5 * generator.MIN)
    m = res.metrics
    for k in ("max_drawdown", "worst_trade", "worst_sequence", "failed_execution_rate", "failed_exit_rate",
              "slippage_usd", "fees_usd", "profit_factor", "expectancy", "by_regime"):
        assert k in m
    assert res.config_fingerprint == cfg.fingerprint()
    for t in res.trades:
        assert t.exit_ts > t.entry_ts and t.fees_usd > 0 and t.slippage_usd > 0


def test_drawdown_helpers():
    assert max_drawdown([100, 120, 60, 130]) == -0.5
    assert worst_sequence([0.1, -0.2, -0.3, 0.1, -0.1]) == -0.5


def test_event_study_uses_matched_controls(store):
    ev = [event_study.StudyEvent(ORGANIC, generator.T0 + 537 * generator.MIN + 30_000, "LISTING")]
    universe = [key(s.address) for s in generator.DEFAULT_SCENARIOS]
    r = event_study.run(store, ev, universe, {"15m": 900_000, "30m": 1_800_000})
    assert r.mean_return["15m"] is not None and r.mean_control_return["15m"] is not None
    assert r.mean_abnormal_return["30m"] > 0


def test_journal_hash_chain(tmp_path, cfg):
    j = Journal(tmp_path / "j.jsonl")
    j.append("signal", {"token": "a"}, cfg.fingerprint())
    j.append("outcome", {"token": "a", "mfe": 0.3}, cfg.fingerprint())
    assert j.verify()
    lines = (tmp_path / "j.jsonl").read_text().splitlines()
    rec = json.loads(lines[0])
    rec["payload"]["token"] = "tampered"
    lines[0] = json.dumps(rec)
    (tmp_path / "j.jsonl").write_text("\n".join(lines) + "\n")
    assert not Journal(tmp_path / "j.jsonl").verify()


def test_outcome_labels_are_multilabel():
    o = TradeOutcome(mfe=0.02, mae=-0.3, duration_ms=1, exit_reason="stop", realized_return=-0.2)
    labs = label(o, catalyst_timing="NEWS_FIRST", catalyst_confirmed=True, social_led=False,
                 manipulation_score=0.1, liquidity_drop=0.4, exhaustion_state="HEALTHY_EXPANSION")
    assert {Outcome.FALSE_BREAKOUT, Outcome.NEWS_DRIVEN, Outcome.LIQUIDITY_FAILURE} <= set(labs)


def test_purged_walk_forward_has_no_overlap():
    samples = [Sample(i * 1000, i * 1000 + 5000, (float(i),), i % 2) for i in range(200)]
    for train, test in purged_walk_forward(samples, 4, embargo_ms=2000):
        assert max(s.label_end_ts for s in train) + 2000 < test[0].ts


def test_logistic_beats_base_rate_on_informative_feature():
    rnd = random.Random(0)
    samples = []
    for i in range(600):
        x = rnd.gauss(0, 1)
        y = 1 if x + rnd.gauss(0, 0.5) > 0 else 0
        samples.append(Sample(i * 1000, i * 1000 + 500, (x, rnd.gauss(0, 1)), y))
    assert evaluate_walk_forward(samples, n_folds=3, embargo_ms=0)["beats_base_rate_all_folds"]
    m = Logistic().fit([s.x for s in samples], [s.y for s in samples])
    assert abs(m.w[0]) > 5 * abs(m.w[1])


def test_feature_dictionary_generated():
    md = registry.markdown()
    assert md.count("\n") == len(registry.FEATURES) + 1
    assert "`price_z_{n}`" in md


def test_feature_dictionary_doc_in_sync():
    from pathlib import Path
    doc = Path(__file__).resolve().parents[2] / "docs" / "research" / "03-feature-dictionary.md"
    assert registry.markdown() in doc.read_text(), "regenerate docs/research/03 with `python -m autopsyx features`"
