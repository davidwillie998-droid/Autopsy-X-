"""Migration 0003 on PostgreSQL: Phase 3A observations load, and the database
re-enforces the observation contract."""
import pytest

from autopsyx.data.normalize3a import normalize_phase3a
from autopsyx.data.raw import RawStore
from autopsyx.data.sql_export import manifest_sql, observation_sql
from autopsyx.providers.store import EventStore

from test_phase2_replay import _psql, needs_pg, pgdb  # noqa: F401  (fixture)
from test_phase3a_funding import FUNDER, WALLET, collect, sig_rows, sys_transfer, tx
from test_phase3a_universe import run3


def _load(pgdb, tmp_path, run_dir):
    obs, _ = normalize_phase3a(str(run_dir))
    stmts = [manifest_sql("r", e) for e in RawStore(run_dir).entries()] + [observation_sql("r", o) for o in obs]
    f = tmp_path / "load.sql"
    f.write_text("BEGIN;\n" + "\n".join(stmts) + "\nCOMMIT;\n")
    r = _psql(pgdb, file=str(f))
    assert r.returncode == 0, r.stderr[:2000]
    return obs


@needs_pg
def test_phase3a_run_loads_and_point_in_time_matches(pgdb, tmp_path):
    run3(tmp_path / "run")
    obs = _load(pgdb, tmp_path, tmp_path / "run")
    assert int(_psql(pgdb, "select count(*) from observations").stdout) == len(obs)
    s = EventStore()
    s.extend(obs)
    cut = sorted(o.ingestion_ts for o in obs)[len(obs) // 2]
    py = sum(len(s.view(cut).observations(k)) for k in {o.kind for o in obs})
    sql = f"select count(*) from observations_as_of(to_timestamp({cut} / 1000.0))"
    assert int(_psql(pgdb, sql).stdout) == py
    assert int(_psql(pgdb, "select count(*) from observations o where o.raw_id is not null and not exists "
                           "(select 1 from raw_manifest m where m.raw_id = o.raw_id)").stdout) == 0
    assert int(_psql(pgdb, "select count(*) from raw_manifest where method='POST'").stdout) > 0


@needs_pg
def test_funding_observations_load(pgdb, tmp_path):
    rows = sig_rows(1)
    collect(tmp_path / "f", rows, {rows[0]["signature"]: tx(rows[0]["signature"], instructions=[sys_transfer(FUNDER, WALLET, 7)])})
    obs = _load(pgdb, tmp_path, tmp_path / "f")
    assert _psql(pgdb, "select value->>'beneficiary_status' from observations where kind='funding_transfer'").stdout.strip() == "UNKNOWN"
    assert len(obs) == 1


ROW = ("insert into observations (run_id,kind,entity,chain,state,observation_ts,source_ts,source_ts_state,ingestion_ts,"
       "provider,raw_id,value,reason,schema_version) values ('r','{kind}','e','solana','{state}',now(),{src},'{src_state}',"
       "now(),'p',{raw},'{value}'::jsonb,'{reason}','3a.1')")


def row(kind="news", state="OBSERVED", src="null", src_state="NOT_OBSERVED", raw="'r'", value='{"a":1}', reason=""):
    return ROW.format(kind=kind, state=state, src=src, src_state=src_state, raw=raw, value=value, reason=reason)


@needs_pg
def test_valid_rows_accepted(pgdb):
    assert _psql(pgdb, row()).returncode == 0
    assert _psql(pgdb, row(state="NOT_OBSERVED", value="{}", reason="none", raw="null")).returncode == 0


@needs_pg
@pytest.mark.parametrize("sql", [
    row(value="{}"),                                                     # OBSERVED without a value
    row(state="ERROR", reason="x"),                                      # non-observed carrying a value
    row(state="NOT_OBSERVED", value="{}"),                               # non-observed without a reason
    row(src_state="OBSERVED"),                                           # source time state OBSERVED but no time
    row(src="now() + interval '1 hour'", src_state="OBSERVED"),          # provider time in the future
    row(raw="null"),                                                     # OBSERVED without provenance
    row(kind="sentiment"),                                               # unknown kind
    row(kind="funding_transfer", value='{"beneficiary_status":"OBSERVED"}'),  # signer promoted to beneficiary
    "insert into raw_manifest (run_id,seq,provider,endpoint,url,request_ts,error,method) values "
    "('r',1,'p','e','u',now(),'x','POST')",                              # POST without archived request body
])
def test_database_rejects_contract_violations(pgdb, sql):
    assert _psql(pgdb, sql).returncode != 0
