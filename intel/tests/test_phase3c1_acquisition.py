import pytest

from autopsyx import phase3c_acquire
from autopsyx.data import acquire


class Clock:
    def __init__(self):
        self.ms = 0

    def now(self):
        return self.ms

    def sleep(self, seconds):
        self.ms += int(seconds * 1000)


def _plan(**overrides):
    data = dict(
        network="solana",
        seed=1,
        strata={"young": 1, "quiet_young": 0, "trending": 0, "established": 0},
        new_pool_pages=1,
        backfill_pages=0,
        duration_s=100,
        cycle_s=10,
        poll_ohlcv_limit=1,
        holders_per_cycle=0,
        lag_ms=60000,
        gt_rate_per_s=1.0,
        ds_rate_per_s=1.0,
        gt_min_rate_per_s=0.1,
        ohlcv_every=1,
        circuit_waits=0,
        rpc_rate_per_s=1.0,
        phase3a=True,
        rpc_page_limit=1,
        rpc_max_pages=1,
        rpc_max_txs=1,
    )
    data.update(overrides)
    return acquire.Plan(**data)


def test_replay_reserve_must_fit_inside_total_duration(tmp_path):
    with pytest.raises(ValueError):
        phase3c_acquire.run(str(tmp_path / "run"), _plan(duration_s=60), replay_reserve_s=60)


def test_guard_prevents_starting_enrichment_when_deadline_is_near(monkeypatch):
    clock = Clock()
    called = []

    class FakeFetcher:
        pass

    picked = [{"pool": "p", "token": "t"}]
    monkeypatch.setattr(
        phase3c_acquire.acquire,
        "enrich",
        lambda *args: called.append(1) or [{"token": "t"}],
    )

    result, stopped = phase3c_acquire._bounded_enrichment(
        FakeFetcher(),
        _plan(),
        picked,
        0,
        deadline_ms=1000,
        now_ms=clock.now,
        guard_s=2,
    )
    assert stopped is True
    assert result == []
    assert called == []


def test_scheduler_uses_protected_replay_window(monkeypatch, tmp_path):
    clock = Clock()
    plan = _plan(duration_s=40, cycle_s=10)
    picked = [{
        "pool": "pool",
        "token": "token",
        "dex": "dex",
        "stratum": "young",
        "created_ts": 1,
        "total_supply": 1,
        "liquidity_usd": 1,
        "h1_txns": 1,
    }]

    monkeypatch.setattr(
        phase3c_acquire.acquire,
        "freeze_universe",
        lambda f, p: {
            "fingerprint": "fp",
            "pools": picked,
            "metadata": {"token": {"total_supply_at_selection": 1}},
        },
    )
    monkeypatch.setattr(
        phase3c_acquire,
        "_bounded_backfill",
        lambda *a, **k: {"pages": 0, "stopped_by_deadline": False},
    )
    monkeypatch.setattr(
        phase3c_acquire,
        "_bounded_enrichment",
        lambda *a, **k: ([], False),
    )

    calls = []

    def poll(*args):
        calls.append(1)
        clock.ms += 1000

    monkeypatch.setattr(phase3c_acquire.acquire, "poll_cycle", poll)

    class Limiter:
        rate = 1.0

    class Client:
        limiter = Limiter()

    clients = {phase3c_acquire.gt.NAME: Client()}

    meta = phase3c_acquire.run(
        str(tmp_path / "run"),
        plan,
        replay_reserve_s=20,
        enrichment_guard_s=5,
        clients=clients,
        now_ms=clock.now,
        sleep=clock.sleep,
    )

    assert meta["scheduler"]["replay_reserve_s"] == 20
    assert meta["scheduler"]["replay_reserve_met"] is True
    assert meta["scheduler"]["replay_actual_s"] >= 20
    assert meta["status"] == "COMPLETE"
    assert len(calls) >= 2


def test_scheduler_has_no_post_replay_enrichment(monkeypatch, tmp_path):
    clock = Clock()
    plan = _plan(duration_s=30, cycle_s=10)
    picked = [{
        "pool": "pool",
        "token": "token",
        "dex": "dex",
        "stratum": "young",
        "created_ts": 1,
        "total_supply": 1,
        "liquidity_usd": 1,
        "h1_txns": 1,
    }]

    monkeypatch.setattr(
        phase3c_acquire.acquire,
        "freeze_universe",
        lambda f, p: {
            "fingerprint": "fp",
            "pools": picked,
            "metadata": {"token": {"total_supply_at_selection": 1}},
        },
    )
    monkeypatch.setattr(
        phase3c_acquire,
        "_bounded_backfill",
        lambda *a, **k: {"pages": 0, "stopped_by_deadline": False},
    )
    monkeypatch.setattr(
        phase3c_acquire,
        "_bounded_enrichment",
        lambda *a, **k: ([], False),
    )

    enrich_calls = []
    original_enrich = phase3c_acquire.acquire.enrich
    monkeypatch.setattr(
        phase3c_acquire.acquire,
        "enrich",
        lambda *args, **kwargs: enrich_calls.append(1) or original_enrich(*args, **kwargs),
    )
    monkeypatch.setattr(phase3c_acquire.acquire, "poll_cycle", lambda *args: setattr(clock, "ms", clock.ms + 1000))

    class Limiter:
        rate = 1.0

    class Client:
        limiter = Limiter()

    clients = {phase3c_acquire.gt.NAME: Client()}
    meta = phase3c_acquire.run(
        str(tmp_path / "run"),
        plan,
        replay_reserve_s=20,
        enrichment_guard_s=2,
        clients=clients,
        now_ms=clock.now,
        sleep=clock.sleep,
    )

    assert meta["status"] == "COMPLETE"
    assert "post_replay" not in meta["scheduler"]
