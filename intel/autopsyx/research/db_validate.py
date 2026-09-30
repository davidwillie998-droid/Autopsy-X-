"""Load a real archive + replay into a disposable PostgreSQL database and run the integrity queries."""
from __future__ import annotations

import json
import subprocess
from pathlib import Path

from ..data.normalize import normalize, restrict_to_selection
from ..data.raw import RawStore
from ..data.sql_export import VALIDATION_QUERIES, journal_sql, manifest_sql, records_sql, replay_sql

STUB = ("create function create_hypertable(rel regclass, col name, if_not_exists boolean default false, "
        "migrate_data boolean default false) returns void language sql as 'select null::void';")


def psql(conn: list[str], db: str, sql: str | None = None, file: str | None = None):
    cmd = ["psql", *conn, "-d", db, "-v", "ON_ERROR_STOP=1", "-qAt"] + (["-f", file] if file else ["-c", sql])
    return subprocess.run(cmd, capture_output=True, text=True)


def run(run_dir: str, replay_dir: str, conn: list[str], db: str, migrations: Path, work: Path) -> dict:
    psql(conn, "postgres", f"drop database if exists {db}")
    assert psql(conn, "postgres", f"create database {db}").returncode == 0
    assert psql(conn, db, STUB).returncode == 0
    for f in sorted(migrations.glob("*.sql")):
        r = psql(conn, db, file=str(f))
        if r.returncode:
            return {"migrations": f"FAILED {f.name}: {r.stderr[:500]}"}
    raw = RawStore(run_dir)
    records, rep = normalize(run_dir)
    records = restrict_to_selection(records, raw.read_json("selection.json"))
    run_id = Path(run_dir).name
    summary = json.loads(Path(replay_dir, "summary.json").read_text())
    jl = [l for l in Path(replay_dir, "journal.jsonl").read_text().splitlines() if l.strip()]
    stmts = [manifest_sql(run_id, e) for e in raw.entries()] + records_sql(records)
    stmts += replay_sql(summary, [json.loads(l)["payload"] for l in jl]) + journal_sql(jl)
    work.mkdir(parents=True, exist_ok=True)
    f = work / "load.sql"
    f.write_text("BEGIN;\n" + "\n".join(stmts) + "\nCOMMIT;\n")
    r = psql(conn, db, file=str(f))
    if r.returncode:
        return {"migrations": "OK", "load": f"FAILED: {r.stderr[:1000]}"}
    counts = {t: int(psql(conn, db, f"select count(*) from {t}").stdout) for t in
              ("raw_manifest", "tokens", "pools", "swaps", "provider_bars", "pool_snapshots", "holder_snapshots",
               "coverage", "replay_runs", "replay_records", "journal")}
    checks = {k: int(psql(conn, db, q).stdout) for k, q in VALIDATION_QUERIES.items()}
    # journal chain continuity inside the database
    chain = psql(conn, db, "select count(*) from journal j where j.seq > 1 and j.prev_hash <> "
                           "(select hash from journal p where p.seq = j.seq - 1)").stdout
    checks["journal_chain_breaks_in_db"] = int(chain)
    version = psql(conn, db, "show server_version").stdout.strip()
    timescale = psql(conn, db, "select count(*) from pg_available_extensions where name='timescaledb'").stdout.strip()
    return {"postgres_version": version, "timescaledb_available": timescale == "1", "migrations": "OK", "load": "OK",
            "statements": len(stmts), "row_counts": counts, "integrity_checks": checks,
            "all_checks_zero": all(v == 0 for v in checks.values())}
