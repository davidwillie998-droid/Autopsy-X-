"""Replay determinism, configuration immutability, schema and transport guarantees."""
import json
import logging
import os
import shutil
import subprocess
import urllib.error
from pathlib import Path

import pytest

from autopsyx import replay
from autopsyx.core.config import Config
from autopsyx.data.normalize import PHASE2_CAPABILITIES as CAPS, normalize, to_store
from autopsyx.data.sql_export import manifest_sql, record_sql, records_sql, replay_sql
from autopsyx.data.raw import RawStore
from autopsyx.providers.base import ProviderError
from autopsyx.providers.http import CircuitBreaker, HttpClient, TokenBucket
from autopsyx.providers.store import EventStore, decode_record

from phase2_fakes import KEY, MIN, as_of_after, real_path_records, real_store, run_fake

REQUIRED = {"token", "chain", "as_of", "configuration_hash", "code_version", "dataset_id", "signal", "risk",
            "entry", "exit", "reason", "outcome", "data_quality"}


def spec(**kw):
    base = dict(start_ts=as_of_after(620), end_ts=as_of_after(699), step_ms=5 * MIN, dataset_id="test:1",
                code_version="test", caps=CAPS)
    return replay.ReplaySpec(**(base | kw))


def test_replay_records_carry_required_fields(cfg):
    res = replay.run(real_store(), cfg, spec())
    assert res.records
    for r in res.records:
        assert REQUIRED <= set(r)
        assert r["configuration_hash"] == cfg.fingerprint()


def test_replay_is_deterministic_to_the_byte(cfg, tmp_path):
    a = replay.run(real_store(), cfg, spec(), tmp_path / "a")
    b = replay.run(real_store(), cfg, spec(), tmp_path / "b")
    assert a.digest == b.digest
    assert (tmp_path / "a" / "journal.jsonl").read_bytes() == (tmp_path / "b" / "journal.jsonl").read_bytes()
    assert (tmp_path / "a" / "summary.json").read_bytes() == (tmp_path / "b" / "summary.json").read_bytes()


def test_replay_of_acquired_archive_is_deterministic(cfg, tmp_path):
    run_fake(tmp_path / "run", cycles=3)
    outs = []
    for _ in range(2):
        records, rep = normalize(str(tmp_path / "run"))
        outs.append(replay.run(to_store(records), cfg, spec(start_ts=rep.first_response_ms,
                                                           end_ts=rep.last_response_ms, step_ms=MIN)).digest)
    assert outs[0] == outs[1]


def test_rerun_into_same_dir_is_rebuilt_not_appended(cfg, tmp_path):
    replay.run(real_store(), cfg, spec(), tmp_path)
    first = (tmp_path / "journal.jsonl").read_bytes()
    replay.run(real_store(), cfg, spec(), tmp_path)
    assert (tmp_path / "journal.jsonl").read_bytes() == first


def test_config_hash_changes_with_config():
    a = Config.load()
    b = Config.load(overrides={"signal": {"max_manipulation_score": 0.41}})
    assert a.fingerprint() != b.fingerprint()
    assert Config.load().fingerprint() == a.fingerprint()


def test_replay_refuses_undeclared_config(cfg):
    other = Config.load(overrides={"risk": {"max_slippage": 0.03}})
    with pytest.raises(replay.ConfigMismatch):
        replay.run(real_store(), other, spec(expected_config_hash=cfg.fingerprint()))


def test_replay_refuses_to_mix_experiments_in_one_journal(cfg, tmp_path):
    replay.run(real_store(), cfg, spec(), tmp_path)
    other = Config.load(overrides={"risk": {"max_slippage": 0.03}})
    with pytest.raises(replay.ConfigMismatch):
        replay.run(real_store(), other, spec(), tmp_path)


def test_no_command_can_execute_trades():
    """Phase 2 has no execution path: no order, wallet, or signing code in the package."""
    root = Path(__file__).resolve().parents[1] / "autopsyx"
    text = "\n".join(p.read_text() for p in root.rglob("*.py"))
    for forbidden in ("place_order", "send_transaction", "sign_transaction", "private_key", "sendTransaction"):
        assert forbidden not in text


# ------------------------------------------------------------------------ schema ----
def test_normalized_records_roundtrip_jsonl(tmp_path):
    run_fake(tmp_path / "run", cycles=2)
    records, _ = normalize(str(tmp_path / "run"))
    EventStore.dump_jsonl(tmp_path / "n.jsonl", records)
    back = [decode_record(json.loads(l)) for l in (tmp_path / "n.jsonl").read_text().splitlines()]
    assert back == records


def test_every_record_type_has_sql_mapping(tmp_path):
    records = real_path_records(bars=5)
    run_fake(tmp_path / "run", cycles=1)
    records += normalize(str(tmp_path / "run"))[0]
    kinds = {type(r).__name__ for r in records}
    assert all(record_sql(r) for r in records), kinds


PG = os.environ.get("AUTOPSYX_PG", "host=/tmp port=55432 user=postgres")


def _psql(db, sql=None, file=None):
    cmd = ["psql", *[f"--{k}={v}" if k != "user" else f"--username={v}" for k, v in
                     (kv.split("=") for kv in PG.split())], "-d", db, "-v", "ON_ERROR_STOP=1", "-qAt"]
    cmd += ["-f", file] if file else ["-c", sql]
    return subprocess.run(cmd, capture_output=True, text=True)


def _pg_available():
    return shutil.which("psql") and _psql("postgres", "select 1").returncode == 0


needs_pg = pytest.mark.skipif(not _pg_available(), reason="DATABASE EXECUTION UNVERIFIED: no PostgreSQL reachable")
MIG = Path(__file__).resolve().parents[1] / "migrations"
STUB = ("create function create_hypertable(rel regclass, col name, if_not_exists boolean default false, "
        "migrate_data boolean default false) returns void language sql as 'select null::void';")


@pytest.fixture
def pgdb():
    db = f"autopsyx_test_{os.getpid()}"
    _psql("postgres", f"drop database if exists {db}")
    assert _psql("postgres", f"create database {db}").returncode == 0
    assert _psql(db, STUB).returncode == 0  # TimescaleDB unavailable: hypertable calls become no-ops
    for f in sorted(MIG.glob("*.sql")):
        r = _psql(db, file=str(f))
        assert r.returncode == 0, r.stderr
    yield db
    _psql("postgres", f"drop database if exists {db}")


@needs_pg
def test_migrations_create_expected_schema(pgdb):
    tables = set(_psql(pgdb, "select table_name from information_schema.tables where table_schema='public'").stdout.split())
    assert {"swaps", "pool_snapshots", "provider_bars", "coverage", "raw_manifest", "replay_runs", "replay_records",
            "journal", "feature_values", "normalization_issues"} <= tables
    assert _psql(pgdb, "select max(version) from schema_version").stdout.strip() == "2"
    idx = _psql(pgdb, "select indexname from pg_indexes where tablename='provider_bars'").stdout
    assert "provider_bars_pit_idx" in idx


@needs_pg
@pytest.mark.parametrize("sql", [
    # negative price
    "insert into tokens values ('solana','t','T','T',null,null,null,null,now()); insert into swaps values ('solana','x',0,now(),now(),1,'p','t','w','buy',1,1,-1,'s')",
    # seen before event: impossible clock ordering
    "insert into swaps values ('solana','x',0,now(),now() - interval '1 hour',1,'p','t','w','buy',1,1,1,'s')",
    # OK status with no value
    "insert into feature_values values ('t','f',now(),null,'OK',null,'1')",
    # coverage claiming beyond what was seen
    "insert into coverage values ('solana','t','p','trades',now() - interval '1 hour',now() + interval '1 hour',now(),'s','r')",
    # unclosed provider bar
    "insert into provider_bars values ('solana','p','t',now(),60000,now(),1,1,1,1,1,'s','r')",
    # manifest row with neither body nor error
    "insert into raw_manifest values ('r',1,'p','e','u',now(),null,null,null,null,null,null,'{}')",
])
def test_database_rejects_invalid_rows(pgdb, sql):
    assert _psql(pgdb, sql).returncode != 0


@needs_pg
def test_duplicate_natural_key_rejected(pgdb):
    row = "insert into swaps values ('solana','x',0,'2026-01-01','2026-01-01',1,'p','t','w','buy',1,1,1,'s')"
    assert _psql(pgdb, row).returncode == 0
    assert _psql(pgdb, row).returncode != 0


@needs_pg
def test_journal_is_append_only_in_database(pgdb):
    _psql(pgdb, "insert into journal (kind,config_hash,label_rules,prev_hash,hash,payload) values ('k','c','1','g','h','{}')")
    _psql(pgdb, "update journal set kind='tampered'")
    _psql(pgdb, "delete from journal")
    assert _psql(pgdb, "select kind from journal").stdout.strip() == "k"


@needs_pg
def test_normalized_archive_and_replay_load_into_database(pgdb, tmp_path, cfg):
    run_fake(tmp_path / "run", cycles=3)
    records, rep = normalize(str(tmp_path / "run"))
    res = replay.run(to_store(records), cfg, spec(start_ts=rep.first_response_ms, end_ts=rep.last_response_ms,
                                                 step_ms=MIN))
    stmts = [manifest_sql("fake", e) for e in RawStore(tmp_path / "run").entries()]
    stmts += records_sql(records)
    stmts += replay_sql(res.summary, res.records)
    f = tmp_path / "load.sql"
    f.write_text("BEGIN;\n" + "\n".join(stmts) + "\nCOMMIT;\n")
    r = _psql(pgdb, file=str(f))
    assert r.returncode == 0, r.stderr[:2000]
    assert int(_psql(pgdb, "select count(*) from replay_records").stdout) == len(res.records)
    assert int(_psql(pgdb, "select count(*) from swaps where raw_id is null").stdout) == 0


# ---------------------------------------------------------------------- transport ----
class _Resp:
    status = 200
    headers = {"Content-Type": "application/json"}

    def __init__(self, body):
        self.body = body

    def read(self):
        return self.body

    def __enter__(self):
        return self

    def __exit__(self, *a):
        return False


def _client(script, sleeps, **kw):
    calls = []

    def opener(req, timeout):
        calls.append(timeout)
        r = script.pop(0)
        if isinstance(r, Exception):
            raise r
        return _Resp(r)

    c = HttpClient("https://x", TokenBucket(1e6, 100, clock=lambda: 0.0, sleep=lambda s: None), sleep=sleeps.append,
                   opener=opener, jitter=lambda: 0.0, **kw)
    return c, calls


def test_backoff_doubles_and_retry_count_is_exact():
    sleeps = []
    c, calls = _client([urllib.error.URLError("x")] * 5, sleeps, max_retries=4, backoff_s=1.0)
    with pytest.raises(ProviderError):
        c.get_raw("/a")
    assert len(calls) == 5 and sleeps == [1.0, 2.0, 4.0, 8.0]


def test_timeout_is_passed_and_retried():
    c, calls = _client([TimeoutError("slow"), b"{}"], [], timeout_s=3.5)
    assert c.get_raw("/a").attempts == 2
    assert calls == [3.5, 3.5]


def test_circuit_recovers_after_cooldown():
    now = [0.0]
    cb = CircuitBreaker(threshold=2, cooldown_s=10, clock=lambda: now[0])
    c, calls = _client([urllib.error.URLError("x")] * 2 + [b"{}"], [], max_retries=0, breaker=cb)
    for _ in range(2):
        with pytest.raises(ProviderError):
            c.get_raw("/a")
    with pytest.raises(ProviderError, match="circuit open"):
        c.get_raw("/a")
    assert len(calls) == 2  # refused without touching the network
    now[0] = 11.0
    assert c.get_raw("/a").status == 200
    assert cb.failures == 0 and cb.opened_at is None


def test_failures_propagate_as_provider_errors_and_are_logged(caplog):
    c, _ = _client([urllib.error.URLError("down")] * 2, [], max_retries=1)
    with caplog.at_level(logging.WARNING, logger="autopsyx.http"):
        with pytest.raises(ProviderError) as e:
            c.get_raw("/a")
    assert e.value.retryable
    msgs = [r.getMessage() for r in caplog.records]
    assert "retry" in msgs and "retries exhausted" in msgs


def test_malformed_json_is_not_retried():
    c, calls = _client([b"<html>"], [])
    with pytest.raises(ProviderError, match="malformed JSON") as e:
        c.get_json("/a")
    assert not e.value.retryable and len(calls) == 1


def test_response_clocks_recorded():
    t = iter([1000, 1250])
    c, _ = _client([b"{}"], [], now_ms=lambda: next(t))
    r = c.get_raw("/a")
    assert (r.request_ts, r.response_ts) == (1000, 1250) and r.body == b"{}"


def test_records_with_own_kind_field_roundtrip(tmp_path):
    """Regression: the Phase 1 JSONL envelope key 'kind' was overwritten by the
    'kind' field of LiquidityEvent and Coverage, so neither could be reloaded."""
    from autopsyx.core.models import Coverage, LiquidityEvent, LiquidityKind
    recs = [LiquidityEvent("solana", "tx", 0, 1, 2, 3, "p", "t", LiquidityKind.REMOVE, 10.0, "w"),
            Coverage("solana", "t", "p", "trades", 0, 10, 20, "s", "r")]
    EventStore.dump_jsonl(tmp_path / "x.jsonl", recs)
    back = [decode_record(json.loads(l)) for l in (tmp_path / "x.jsonl").read_text().splitlines()]
    assert back == recs
    # a legacy line without _type still decodes when it has no inner 'kind' collision to lose
    lq = {"kind": "swap", "chain": "solana", "tx_hash": "t", "log_index": 0, "ts": 1, "seen_ts": 1, "block": 1,
          "pool": "p", "token": "t", "wallet": "w", "side": "buy", "token_amount": 1.0, "quote_usd": 1.0, "price_usd": 1.0}
    assert decode_record(lq).side.value == "buy"  # legacy envelope still readable


def test_early_life_experiment_measures_and_checks_safety(cfg):
    from autopsyx.research import early_life
    res = replay.run(real_store(), cfg, spec())
    out = early_life.evaluate(res.records, cfg.section("signal")["min_coverage"])
    assert out["S1_safe"]
    assert set(out["by_age"]) <= {"<1h", "1-6h", "6-24h", "1-7d", ">7d", "unknown_age"}
    fake = [dict(res.records[0], move_class="UNCLASSIFIED", signal="HIGH_CONVICTION_CONTINUATION")]
    assert not early_life.evaluate(fake, 0.7)["S1_safe"]  # the invariant check can fail
