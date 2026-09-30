import math

import pytest

from autopsyx.core import stats
from autopsyx.core.models import PoolSnapshot, Side, Swap, TokenMeta, TokenRef
from autopsyx.core.values import DataStatus, combine, missing, ok
from autopsyx.core.failure import FailureMode
from autopsyx.providers.store import EventStore
from autopsyx.quality import checks


def _swap(i, ts, seen=None, tx=None, price=1.0):
    return Swap("solana", tx or f"t{i}", 0, ts, seen if seen is not None else ts, ts // 400, "p", "tok",
                f"w{i}", Side.BUY, 1.0, 1.0, price)


def test_missing_never_becomes_zero():
    out = combine(lambda a, b: a + b, ok(1.0), missing("provider down"))
    assert out.value is None
    assert out.status == DataStatus.MISSING
    assert "provider down" in out.reason


def test_combine_propagates_worst_status():
    stale = ok(2.0)
    stale = type(stale)(2.0, DataStatus.STALE, "old")
    out = combine(lambda a, b: a * b, ok(3.0), stale)
    assert out.value == 6.0 and out.status == DataStatus.STALE


def test_combine_division_by_zero_is_missing():
    assert combine(lambda a, b: a / b, ok(1.0), ok(0.0)).status == DataStatus.MISSING


def test_robust_z_resists_single_outlier():
    hist = [0.0, 0.01, -0.01, 0.02, -0.02] * 10 + [5.0]
    assert stats.robust_z(0.02, hist) < 3
    assert stats.robust_z(1.0, hist) > 10


def test_percentile_and_hhi():
    assert stats.percentile_rank(5, [1, 2, 3, 4]) == 1.0
    assert stats.hhi([1, 1, 1, 1]) == pytest.approx(0.25)
    assert stats.hhi([1]) == 1.0


def test_point_in_time_hides_unseen_records():
    s = EventStore()
    s.add(_swap(1, ts=1_000, seen=1_000))
    s.add(_swap(2, ts=1_500, seen=9_000))  # happened early, reported late
    view = s.view(5_000)
    assert [x.wallet for x in view.swaps("solana:tok")] == ["w1"]
    assert len(s.view(9_000).swaps("solana:tok")) == 2


def test_jsonl_roundtrip(tmp_path):
    recs = [TokenMeta(TokenRef("solana", "tok"), "T", "Tok", 0, "c", 1e9, 0), _swap(1, 10)]
    p = tmp_path / "d.jsonl"
    EventStore.dump_jsonl(p, recs)
    s = EventStore.load_jsonl(p)
    assert s.view(10).tokens()[0].ref.key == "solana:tok"
    assert s.view(10).swaps("solana:tok")[0].side == Side.BUY


def test_dedupe_keeps_earliest_seen():
    rep = checks.QualityReport("solana:tok")
    a = _swap(1, 100, seen=200, tx="x")
    b = _swap(1, 100, seen=150, tx="x")
    out = checks.dedupe_swaps([a, b], rep)
    assert len(out) == 1 and out[0].seen_ts == 150 and rep.duplicates_removed == 1


def test_staleness_and_conflict_flags(cfg):
    dq = cfg.section("data_quality")
    snaps = [PoolSnapshot("solana", "p1", "tok", 0, 0, 1e5, 1.0, "A"),
             PoolSnapshot("solana", "p2", "tok", 0, 0, 1e5, 1.2, "B")]
    _, rep = checks.run("solana:tok", [], snaps, as_of=10_000_000, cfg=dq)
    assert FailureMode.STALE_DATA in rep.failures
    _, rep = checks.run("solana:tok", [], snaps, as_of=1_000, cfg=dq)
    assert FailureMode.CONFLICTING_DATA in rep.failures


def test_no_data_flag(cfg):
    _, rep = checks.run("solana:tok", [], [], as_of=1_000, cfg=cfg.section("data_quality"))
    assert FailureMode.NO_DATA in rep.failures


def test_reorg_filter_drops_shallow_blocks():
    rep = checks.QualityReport("solana:tok")
    s1, s2 = _swap(1, 400 * 100), _swap(2, 400 * 195)
    kept = checks.drop_unconfirmed([s1, s2], head_block=200, min_conf=32, report=rep)
    assert kept == [s1] and rep.unconfirmed_dropped == 1


def test_symbol_collisions():
    t = [TokenMeta(TokenRef("solana", a), "PEPE", "x", 0, None, None, 0) for a in ("a1", "a2")]
    assert checks.symbol_collisions(t) == {"PEPE": ["solana:a1", "solana:a2"]}


def test_block_gaps():
    assert checks.block_gaps([1, 2, 3, 50, 51], max_gap=10) == [(3, 50)]
