"""Phase 3A verification: evidence, coverage matrix, report and system status.

``collect`` runs every Phase 3A gate on every archive and returns the
evidence dict (artifacts/phase3a/PHASE3A_EVIDENCE.json) and the coverage
matrix (artifacts/phase3a/PHASE3A_COVERAGE.json). ``render`` and
``render_status`` turn the evidence into docs/PHASE3A_REPORT.md and
docs/SYSTEM_STATUS.md. Renderers compute nothing: every number they print
is a value already in the evidence.
"""
from __future__ import annotations

import hashlib
import json
import os
import subprocess
import sys
from collections import Counter
from pathlib import Path

from .. import replay
from ..core.config import Config
from ..core.observation import ContractViolation, validate
from ..data.normalize import PHASE2_CAPABILITIES, normalize, replay_window, restrict_to_selection, to_store
from ..data.normalize3a import normalize_phase3a, observations_sha256
from ..data import provenance
from ..data.raw import RawStore
from ..data.sql_export import manifest_sql, observation_sql
from ..providers.store import EventStore
from . import db_validate, lookahead_audit, phase2_report, phase2_verify
from . import phase3a_coverage as cov
from . import phase3a_readiness as rd
from . import phase3a_state as st
from . import phase3a_telemetry as tel
from . import trace_check

ROOT = phase2_verify.ROOT
BASELINE = "30fe094"  # final Phase 2 commit
HYPOTHESIS_FILES = ["docs/research/14-research-hypotheses.md"]
NOT_CLAIMED = ["H2", "H5", "H6", "H7"]
BASELINE_EVIDENCE_COMMIT = "8df2918"  # Phase 3A evidence over A, B, C before archive D
INCLUSION_RULE = ("an archive enters the evidence only if data.provenance.verify() returns verified: its runner "
                  "dataset hash is recorded and equals, exactly, the hash rebuilt twice from the committed raw "
                  "archive (and, where the runner sealed canonical files, the hash of those committed files), and a "
                  "sealed archive's acquisition reports COMPLETE; any other archive is listed as excluded with the "
                  "verification result")
ARCHIVE_DIRS = [ROOT / "intel" / "datasets" / "phase2" / "runs", ROOT / "intel" / "datasets" / "phase3a" / "runs"]

# Test files changed since the Phase 2 baseline, with the reason. Phase 3A
# evidence lists the actual diff next to this so a reviewer can compare.
TEST_CHANGES_EXPLAINED = {
    "intel/tests/test_phase2_evidence.py": "the frozen Phase 2 status rendering now lives in docs/PHASE2_SYSTEM_STATUS.md "
                                           "because docs/SYSTEM_STATUS.md is the living Phase 3A status; same assertion, "
                                           "new path",
    "intel/tests/test_phase2_replay.py": "schema version check expects one row per migration file instead of the literal "
                                         "2, since migration 0003 exists",
    "intel/tests/test_transport.py": "two tests added (POST, attempt log); none changed",
}
LIMITATIONS_FIXED = [
    "Multi-day collection was not performed: GitHub-hosted jobs stop after hours and scheduled workflows run only on "
    "the default branch. The collector is ready for it (frozen universe, chained runs that refuse an edited universe).",
    "Funding transfers, chain-derived liquidity events, news and social exist only where an archive was acquired with "
    "the Phase 3A plan; the Phase 2 archives report them UNAVAILABLE.",
    "Liquidity add/remove detection sees only venues whose vault token accounts are owned by the pool address; other "
    "venues are reported as a coverage gap, never as no liquidity change.",
    "GDELT gives crawler time, not publication time; news publication time is NOT_OBSERVED by construction.",
    "Whether a news item or post truly concerns its token is not verified (reference_verified_state UNKNOWN).",
    "X and Telegram are UNAVAILABLE: no credentials are held and none were substituted.",
    "Funding beneficiaries are never inferred; every transfer carries beneficiary_status UNKNOWN.",
    "Freshness has one approved threshold (max_price_age_ms), applied to the per-cycle market endpoints only.",
    "Readiness thresholds do not exist yet; the gate stays NOT_READY until a human approves values.",
    "TimescaleDB is unavailable here; hypertable calls are stubbed on PostgreSQL 16 as in Phase 2.",
]


def _sha(obj) -> str:
    return hashlib.sha256(json.dumps(obj, sort_keys=True).encode()).hexdigest()


def archives() -> list[Path]:
    out = []
    for base in ARCHIVE_DIRS:
        if base.exists():
            out += sorted(p for p in base.iterdir() if p.is_dir() and (p / "manifest.jsonl").exists())
    return out


def replay_archive(d: Path, cfg: Config, work: Path, code_version: str) -> dict:
    raw = RawStore(d)
    records, rep = normalize(str(d))
    obs1, issues = normalize_phase3a(str(d))
    obs2, _ = normalize_phase3a(str(d))
    out = {"dataset_sha256": rep.dataset_sha256, "observations_sha256": [observations_sha256(obs1), observations_sha256(obs2)],
           "observations_identical": observations_sha256(obs1) == observations_sha256(obs2),
           "observation_count": len(obs1), "issues_by_code": dict(sorted(Counter(i.code for i in issues).items()))}
    win = replay_window(raw)
    if win is None:
        return out | {"replayable": False, "reason": "no live poll responses in archive (run ended during backfill)",
                      "identical": None, "lookahead_all_passed": None}
    sel = restrict_to_selection(records, raw.read_json("selection.json"))
    digests = []
    for i in (1, 2):
        spec = replay.ReplaySpec(start_ts=win[0], end_ts=win[1], step_ms=5 * 60_000,
                                 dataset_id=f"{d.name}:{rep.dataset_sha256[:16]}", code_version=code_version,
                                 caps=PHASE2_CAPABILITIES, expected_config_hash=cfg.fingerprint())
        o = work / d.name / f"replay_{i}"
        res = replay.run(to_store(sel), cfg, spec, o)
        digests.append({"records_sha256": res.digest,
                        "journal_sha256": hashlib.sha256((o / "journal.jsonl").read_bytes()).hexdigest()})
    step = (win[1] - win[0]) // 5
    la = lookahead_audit.run(sel, cfg, PHASE2_CAPABILITIES, [win[0] + step * k for k in (1, 2, 3, 4)])
    return out | {"replayable": True, "window_ms": list(win), "replays": digests, "identical": digests[0] == digests[1],
                  "lookahead_all_passed": la["all_passed"], "lookahead_checks": la["summary"]}


def assessments(d: Path, window: list[int] | None) -> dict:
    """Creator / holder state for every universe token at the first and last poll."""
    raw = RawStore(d)
    obs, _ = normalize_phase3a(str(d))
    s = EventStore()
    s.extend(obs)
    _, pools = cov.universe(raw)
    entries = raw.entries()
    times = window or ([min(e.request_ts for e in entries), max((e.response_ts or e.request_ts) for e in entries)]
                       if entries else [])
    out = {}
    for label, t in zip(("first", "last"), times):
        for kind in st.STATE_KINDS:
            a = [st.assess(s.view(t), kind, p["token"]) for p in pools]
            out[f"{kind}@{label}"] = {"as_of": t, "states": dict(sorted(Counter(x.state for x in a).items())),
                                      "hindsight": dict(sorted(Counter(st.hindsight(s, x) for x in a).items()))}
    return out


def postgres(d: Path, conn: list[str] | None, work: Path) -> dict:
    if not conn:
        return {"status": "DATABASE EXECUTION UNVERIFIED: no server"}
    db = f"phase3a_{d.name.replace('-', '_')}"
    P = db_validate.psql
    P(conn, "postgres", f"drop database if exists {db}")
    if P(conn, "postgres", f"create database {db}").returncode:
        return {"status": "DATABASE EXECUTION UNVERIFIED: cannot create database"}
    P(conn, db, db_validate.STUB)
    for f in sorted((ROOT / "intel" / "migrations").glob("*.sql")):
        r = P(conn, db, file=str(f))
        if r.returncode:
            return {"status": f"FAILED migration {f.name}"}
    obs, _ = normalize_phase3a(str(d))
    stmts = [manifest_sql(d.name, e) for e in RawStore(d).entries()] + [observation_sql(d.name, o) for o in obs]
    work.mkdir(parents=True, exist_ok=True)
    f = work / f"{d.name}_observations.sql"
    f.write_text("BEGIN;\n" + "\n".join(stmts) + "\nCOMMIT;\n")
    r = P(conn, db, file=str(f))
    if r.returncode:
        return {"status": "FAILED load", "error": r.stderr[:300]}
    q = lambda sql: int(P(conn, db, sql).stdout.strip() or -1)
    s = EventStore()
    s.extend(obs)
    cut = sorted(o.ingestion_ts for o in obs)[len(obs) // 2] if obs else 0
    py = sum(len(s.view(cut).observations(k)) for k in {o.kind for o in obs})
    out = {"status": "LOADED", "migrations": len(list((ROOT / "intel" / "migrations").glob("*.sql"))),
           "observations_loaded": q("select count(*) from observations"), "observations_expected": len(obs),
           "pit_rows_sql": q(f"select count(*) from observations_as_of(to_timestamp({cut} / 1000.0))") if obs else 0,
           "pit_rows_python": py,
           "observation_raw_ids_not_in_manifest": q("select count(*) from observations o where o.raw_id is not null and "
                                                    "not exists (select 1 from raw_manifest m where m.raw_id = o.raw_id)")}
    out["all_checks_pass"] = (out["observations_loaded"] == out["observations_expected"]
                              and out["pit_rows_sql"] == out["pit_rows_python"]
                              and out["observation_raw_ids_not_in_manifest"] == 0)
    P(conn, "postgres", f"drop database if exists {db}")
    return out


def multi_day(arch: list[Path]) -> dict:
    groups: dict[str, list[dict]] = {}
    for d in arch:
        raw = RawStore(d)
        m = raw.read_json("run.json") or {}
        u = raw.read_json("universe.json")
        key = u["fingerprint"] if u else f"selection:{d.name}"
        es = raw.entries()
        lo = min((e.request_ts for e in es), default=None)
        hi = max(((e.response_ts or e.request_ts) for e in es), default=None)
        groups.setdefault(key, []).append({"archive": d.name, "first_ms": lo, "last_ms": hi, "status": m.get("status")})
    rows = []
    for k, g in sorted(groups.items()):
        lo = min(x["first_ms"] for x in g if x["first_ms"] is not None)
        hi = max(x["last_ms"] for x in g if x["last_ms"] is not None)
        days = {__import__("datetime").datetime.utcfromtimestamp(t / 1000).date().isoformat()
                for x in g for t in (x["first_ms"], x["last_ms"]) if t is not None}
        rows.append({"universe": k, "archives": [x["archive"] for x in g], "span_ms": hi - lo,
                     "span_days": round((hi - lo) / 86_400_000, 6), "utc_dates": sorted(days)})
    longest = max((r["span_days"] for r in rows), default=0.0)
    return {"groups": rows, "longest_span_days": longest,
            "performed": any(len(r["utc_dates"]) > 1 and len(r["archives"]) > 1 for r in rows),
            "definition": "performed = some frozen universe was collected by more than one chained run across more "
                          "than one UTC date"}


def hypotheses_frozen() -> dict:
    files = {}
    for f in HYPOTHESIS_FILES:
        files[f] = {"sha256": hashlib.sha256((ROOT / f).read_bytes()).hexdigest(),
                    "diff_since_baseline": phase2_verify.git("diff", "--stat", BASELINE, "--", f) or "(no changes)"}
    src = (Path(phase2_verify.__file__)).read_text()
    i = src.index("\nHYPOTHESES = [")
    block = src[i: src.index("\n]\n", i) + 3]
    base = phase2_verify.git("show", f"{BASELINE}:intel/autopsyx/research/phase2_verify.py")
    j = base.index("\nHYPOTHESES = [")
    return {"files": files, "phase2_hypotheses_table_unchanged": block == base[j: base.index("\n]\n", j) + 3],
            "tested_in_phase3a": [], "not_claimed": NOT_CLAIMED}


def cross_seed(arch: list[Path], seeds=(1, 2)) -> dict:
    """Recompute observations and the coverage matrix in fresh processes with different hash seeds."""
    code = ("import json,hashlib,sys;sys.path.insert(0,'.');from autopsyx.core.config import Config;"
            "from autopsyx.research import phase3a_verify as v, phase3a_coverage as c;"
            "from autopsyx.data.normalize3a import normalize_phase3a, observations_sha256;"
            "from pathlib import Path;a=[Path(x) for x in sys.argv[1:]];m=c.matrix(a,{},Config.load());"
            "print(hashlib.sha256(json.dumps(m,sort_keys=True).encode()).hexdigest(),"
            "'|'.join(observations_sha256(normalize_phase3a(str(d))[0]) for d in a))")
    out = []
    for s in seeds:
        r = subprocess.run([sys.executable, "-c", code, *map(str, arch)], cwd=ROOT / "intel", capture_output=True, text=True,
                           env=dict(os.environ, PYTHONHASHSEED=str(s)))
        out.append({"seed": s, "digest": hashlib.sha256(r.stdout.encode()).hexdigest(), "exit_code": r.returncode})
    return {"runs": out, "identical": len({x["digest"] for x in out}) == 1 and all(x["exit_code"] == 0 for x in out)}


FUNNEL_STEPS = [("attempted", "discovered"), ("successful", "attempted"), ("evaluable", "successful"),
                ("classified", "evaluable")]


def funnel(d: Path, work: Path, replayable: bool) -> dict:
    """The Phase 2 funnel (phase2_verify.funnel, unchanged definitions) with every
    ratio stated as numerator / denominator. For an archive without a replay,
    evaluable and classified are not measured (None), not zero."""
    raw = RawStore(d)
    records, _ = normalize(str(d))
    sel = restrict_to_selection(records, raw.read_json("selection.json"))
    j = work / d.name / "replay_1" / "journal.jsonl"
    f = phase2_verify.funnel(raw, records, sel, j if replayable else None)
    counts = {k: f[k] for k in ("discovered", "attempted", "successful", "evaluable", "classified")}
    if not replayable:
        counts["evaluable"] = counts["classified"] = None
    ratios = []
    for num, den in FUNNEL_STEPS:
        n, dd = counts[num], counts[den]
        ratios.append({"step": f"{den} -> {num}", "numerator": n, "denominator": dd,
                       "share": round(n / dd, 6) if isinstance(n, int) and isinstance(dd, int) and dd else None,
                       "numerator_definition": f["definitions"][num], "denominator_definition": f["definitions"][den],
                       "not_measured_reason": None if n is not None and dd is not None else
                       "archive not replayable: no replay assessment exists, so evaluable and classified are not measured"})
    return {"counts": counts, "ratios": ratios, "definitions": f["definitions"],
            "per_token_reduction": {t["token"]: t["reduction_reason"] for t in f["per_token"]}}


def phase2_checks(d: Path, work: Path, replayable: bool, pg: list[str] | None) -> dict:
    """Existing Phase 2 checks re-run at this commit: clock and hash audit of the
    raw archive, journal hash chain, and the Phase 2 PostgreSQL validation."""
    audit = phase2_report.raw_audit(str(d))
    clocks = {k: sum(int(v.get(k, 0)) for v in audit["by_provider"].values())
              for k in ("missing_request_ts", "missing_response_ts", "response_before_request", "out_of_order_response",
                        "hash_mismatch", "missing_body_file", "length_mismatch")}
    # Reported, not gated: a provider may legitimately answer with an error or non-JSON body
    # (recorded as ERROR observations), and identical repeats are expected from quiet pools.
    informational = {k: sum(int(v.get(k, 0)) for v in audit["by_provider"].values())
                     for k in ("malformed_json", "partial_or_error_body", "empty_body", "identical_body_repeats")}
    out = {"raw_audit": audit, "clock_and_hash_violations": clocks, "informational_body_counts": informational}
    if replayable:
        rd_ = str(work / d.name / "replay_1")
        out["journal_audit"] = phase2_report.journal_audit(rd_)
        if pg:
            v = db_validate.run(str(d), rd_, pg, f"p3a_p2_{d.name.replace('-', '_')}", ROOT / "intel" / "migrations",
                                work / d.name / "db_p2")
            out["postgres_phase2"] = {k: v.get(k) for k in ("all_checks_zero", "integrity_checks", "row_counts",
                                                            "postgres_version", "timescaledb_available")}
        else:
            out["postgres_phase2"] = {"status": "DATABASE EXECUTION UNVERIFIED: no server"}
    else:
        out["journal_audit"] = None
        out["postgres_phase2"] = {"status": "not run: archive not replayable (no journal to load)"}
    j = out["journal_audit"]
    out["passed"] = (all(v == 0 for v in clocks.values()) and audit["referenced_but_missing"] == 0
                     and (j is None or (j["chain_breaks"] == 0 and j["hash_mismatches"] == 0))
                     and out["postgres_phase2"].get("all_checks_zero", True) is not False)
    return out


COMPARE_METRICS = ["provider_error_rate", "freshness_compliance", "universe_tokens", "coverage_rows",
                   "liquidity_vault_delta_share"]


def _aggregate(runs: list[dict], rows: list[dict]) -> dict:
    T = cov.totals_of(rows)
    req = sum(t["requests"] for r in runs for t in r["telemetry"].values())
    err = sum(t["errors"] for r in runs for t in r["telemetry"].values())
    gov_n = sum(r["freshness"]["governed_evaluations"] for r in runs)
    gov_s = sum(r["freshness"]["governed_stale"] for r in runs)
    return {"provider_requests": req, "provider_errors": err, "provider_error_rate": round(err / req, 6) if req else None,
            "freshness_evaluations": gov_n, "freshness_stale": gov_s,
            "freshness_compliance": round((gov_n - gov_s) / gov_n, 6) if gov_n else None,
            "coverage_rows": len(rows), "universe_tokens": len({r["token"]["value"] for r in rows}),
            "coverage_share": {d: T[d]["positive_share"] for d in cov.DIMENSIONS[2:]},
            "coverage_rows_observed": {d: T[d][T[d]["positive_state"]] for d in cov.DIMENSIONS[2:]},
            "liquidity_vault_delta_rows": T["liquidity_events"]["rows_with_vault_delta_events"],
            "liquidity_vault_delta_share": T["liquidity_events"]["vault_delta_share"], "totals": T}


def baseline_comparison(ev_runs: list[dict], rows: list[dict], agg_all: dict, integrity: dict) -> dict:
    """Committed A/B/C evidence vs the same archives recomputed now vs A/B/C/D.

    SAMPLE EXPANSION: the A/B/C part reproduces the committed baseline exactly
    and the totals differ only because archive D adds rows. EVIDENCE CHANGE:
    the A/B/C part itself no longer reproduces the baseline. Phase 3A defines no
    statistical test, so no difference is called an improvement or a decline."""
    src = phase2_verify.git("show", f"{BASELINE_EVIDENCE_COMMIT}:artifacts/phase3a/PHASE3A_EVIDENCE.json")
    base = json.loads(src)
    names = [r["archive"] for r in base["archives"]]
    sub_runs = [r for r in ev_runs if r["archive"] in names]
    sub_rows = [r for r in rows if r["archive"]["value"] in names]
    abc = _aggregate(sub_runs, sub_rows)
    b = base["aggregates"]
    metrics = []
    keys = COMPARE_METRICS + [f"coverage_share.{d}" for d in cov.DIMENSIONS[2:]]
    for k in keys:
        get = (lambda a, k=k: a["coverage_share"][k.split(".", 1)[1]]) if k.startswith("coverage_share.") else \
              (lambda a, k=k: a[k])
        bv, cv, nv = get(b), get(abc), get(agg_all)
        metrics.append({"metric": k, "baseline_abc_committed": bv, "abc_recomputed_now": cv, "abcd": nv,
                        "abc_reproduces_baseline": bv == cv,
                        "difference_abcd_minus_baseline": round(nv - bv, 6) if isinstance(nv, (int, float))
                        and isinstance(bv, (int, float)) else None})
    funnel_sum = lambda rs, k: sum(r["funnel"]["counts"][k] for r in rs if isinstance(r["funnel"]["counts"][k], int))
    sample = {k: {"abc": funnel_sum(sub_runs, k), "abcd": funnel_sum(ev_runs, k)}
              for k in ("discovered", "attempted", "successful", "evaluable", "classified")}
    sample["archives"] = {"abc": len(sub_runs), "abcd": len(ev_runs)}
    sample["coverage_rows"] = {"abc": len(sub_rows), "abcd": len(rows)}
    lookahead = {r["archive"]: r["replay"]["lookahead_all_passed"] for r in ev_runs}
    replays = {r["archive"]: r["replay"]["identical"] for r in ev_runs}
    reproduces = all(m["abc_reproduces_baseline"] for m in metrics)
    return {"baseline_commit": BASELINE_EVIDENCE_COMMIT, "baseline_archives": names,
            "added_archives": [r["archive"] for r in ev_runs if r["archive"] not in names],
            "sample": sample, "metrics": metrics, "lookahead_by_archive": lookahead, "replay_identical_by_archive": replays,
            "baseline_integrity": base["integrity"], "current_integrity": integrity,
            "abc_reproduces_baseline": reproduces,
            "classification": "SAMPLE EXPANSION" if reproduces else "EVIDENCE CHANGE",
            "interpretation_rule": "differences are descriptive; Phase 3A defines no statistical test, so no "
                                   "difference is called an improvement, and none implies predictive power or edge"}


def collect(work: Path, pg: list[str] | None) -> tuple[dict, dict]:
    cfg = Config.load()
    head = phase2_verify.git("rev-parse", "HEAD")
    dirty = bool(phase2_verify.git("status", "--porcelain", "--", "intel/autopsyx", "intel/config", "intel/migrations"))
    code_version = head + ("-dirty" if dirty else "")
    candidates = archives()
    prov = {d.name: provenance.verify(str(d)) for d in candidates}
    arch = [d for d in candidates if prov[d.name]["verified"]]
    excluded = [{"archive": d.name, "family": d.parent.parent.name, "verification": prov[d.name],
                 "label": "AUDIT / REFERENCE ONLY — PROVENANCE HASH UNAVAILABLE" if prov[d.name]["source"] == "none"
                 else "EXCLUDED — PROVENANCE CHECK FAILED",
                 "reason": "provenance not verifiable: " + prov[d.name]["scope"]}
                for d in candidates if not prov[d.name]["verified"]]
    policy = tel.freshness_policy(cfg)
    runs, rp = [], {}
    for d in arch:
        raw = RawStore(d)
        r = replay_archive(d, cfg, work, code_version)
        rp[d.name] = r
        es = raw.entries()
        obs, _ = normalize_phase3a(str(d))
        bad_contract = 0
        for o in obs:
            try:
                validate(o)
            except ContractViolation:
                bad_contract += 1
        manifest_ids = {e.raw_id for e in es if e.raw_id}
        audit = phase2_report.raw_audit(str(d))
        src, pools = cov.universe(raw)
        u = raw.read_json("universe.json")
        runs.append({
            "archive": d.name, "family": d.parent.parent.name, "run_status": (raw.read_json("run.json") or {}).get("status"),
            "universe": {"source": src, "tokens": len({p["token"] for p in pools}),
                         "fingerprint": u["fingerprint"] if u else None},
            "exchanges": len(es), "replay": r,
            "observations_by_kind_state": dict(sorted(Counter(f"{o.kind}|{o.state.value}" for o in obs).items())),
            "contract_violations": bad_contract,
            "observation_raw_ids_not_in_manifest": sum(1 for o in obs if o.raw_id and o.raw_id not in manifest_ids),
            "raw_bodies_referenced_but_missing": audit["referenced_but_missing"],
            "telemetry": tel.provider_telemetry(es), "freshness": tel.freshness(es, policy),
            "assessments": assessments(d, r.get("window_ms")),
            "postgres": postgres(d, pg, work / "db"),
            "provenance": prov[d.name],
            "funnel": funnel(d, work, r["replayable"]),
            "phase2_checks": phase2_checks(d, work, r["replayable"], pg),
        })
    m = cov.matrix(arch, rp, cfg)
    req = sum(t["requests"] for r in runs for t in r["telemetry"].values())
    err = sum(t["errors"] for r in runs for t in r["telemetry"].values())
    gov_n = sum(r["freshness"]["governed_evaluations"] for r in runs)
    gov_s = sum(r["freshness"]["governed_stale"] for r in runs)
    T = m["totals"]
    md = multi_day(arch)
    tokens = sorted({row["token"]["value"] for row in m["rows"]})
    agg = {
        "provider_requests": req, "provider_errors": err, "provider_error_rate": round(err / req, 6) if req else None,
        "freshness_evaluations": gov_n, "freshness_stale": gov_s,
        "freshness_compliance": round((gov_n - gov_s) / gov_n, 6) if gov_n else None,
        "coverage_rows": m["row_count"], "universe_tokens": len(tokens),
        "coverage_share": {d: T[d]["positive_share"] for d in cov.DIMENSIONS[2:]},
        "coverage_rows_observed": {d: T[d][T[d]["positive_state"]] for d in cov.DIMENSIONS[2:]},
        "liquidity_vault_delta_rows": T["liquidity_events"]["rows_with_vault_delta_events"],
        "liquidity_vault_delta_share": T["liquidity_events"]["vault_delta_share"],
        "multi_day_performed": md["performed"], "multi_day_longest_span_days": md["longest_span_days"],
        "archives": len(arch), "replayable_archives": sum(1 for r in runs if r["replay"]["replayable"]),
    }
    scope = phase2_verify.scope_audit(BASELINE)
    changed_tests = sorted(phase2_verify.git("diff", "--name-only", "--diff-filter=MD", BASELINE, "--",
                                             "intel/tests").split())
    seeds = cross_seed(arch)
    ev = {
        "schema": "phase3a.evidence.1",
        "repository": {"branch": phase2_verify.git("branch", "--show-current"), "head": head, "code_version": code_version,
                       "phase2_baseline": phase2_verify.git("rev-parse", BASELINE),
                       "log": phase2_verify.git("log", "--oneline", f"{BASELINE}..HEAD")},
        "configuration_hash": cfg.fingerprint(),
        "tests": phase2_verify.pytest_counts(),
        "scope": {"engine_diff_since_phase2": scope["engine_diff_stat"],
                  "engine_changes_unexplained": scope["engine_changes_unexplained"],
                  "engine_changes_unexplained_count": len(scope["engine_changes_unexplained"]),
                  "config_lines_removed": scope["config_lines_removed"],
                  "config_lines_removed_count": len(scope["config_lines_removed"]),
                  "forbidden_terms_present": scope["forbidden_terms_present"],
                  "phase2_rule_freeze": phase2_verify.rule_freeze(ARCHIVE_DIRS[0]),
                  "hypotheses": hypotheses_frozen(),
                  "existing_tests_changed": changed_tests, "test_changes_explained": TEST_CHANGES_EXPLAINED,
                  "strategy_logic_added": False},
        "freshness_policy": {"policy": policy, **tel.policy_freeze(cfg)},
        "archives": runs,
        "coverage": {"file": "artifacts/phase3a/PHASE3A_COVERAGE.json", "sha256": _sha(m), "row_count": m["row_count"],
                     "blank_cells": m["blank_cells"], "totals": T, "state_rule": m["state_rule"]},
        "multi_day": md,
        "aggregates": agg,
        "cross_seed_determinism": seeds,
        "limitations": LIMITATIONS_FIXED,
        "inclusion": {"rule": INCLUSION_RULE, "included": [d.name for d in arch], "excluded": excluded},
    }
    replayable = [r for r in runs if r["replay"]["replayable"]]
    integrity = {
        "replay_determinism": bool(replayable) and all(r["replay"]["identical"] for r in replayable)
                              and all(r["replay"]["observations_identical"] for r in runs) and seeds["identical"],
        "point_in_time_validity": T["point_in_time_validity"]["FAILED"] == 0
                                  and all(r["replay"]["lookahead_all_passed"] is not False for r in runs),
        "evidence_integrity": all(r["observation_raw_ids_not_in_manifest"] == 0 and r["raw_bodies_referenced_but_missing"] == 0
                                  and r["postgres"].get("all_checks_pass", pg is None) for r in runs),
        "freshness_policy_frozen": ev["freshness_policy"]["identical_to_frozen"],
        "scope_clean": (not scope["engine_changes_unexplained"] and not scope["config_lines_removed"]
                        and not scope["forbidden_terms_present"] and ev["scope"]["phase2_rule_freeze"]["identical_to_frozen"]
                        and ev["scope"]["hypotheses"]["phase2_hypotheses_table_unchanged"]
                        and all(v["diff_since_baseline"] == "(no changes)" for v in ev["scope"]["hypotheses"]["files"].values())
                        and set(changed_tests) <= set(TEST_CHANGES_EXPLAINED)),
        "no_blank_cells": m["blank_cells"] == 0,
        "contract_valid": all(r["contract_violations"] == 0 for r in runs),
        "tests_green": ev["tests"]["failed"] == 0 and ev["tests"]["errors"] == 0 and ev["tests"]["exit_code"] == 0,
    }
    ev["integrity"] = integrity
    ev["baseline_comparison"] = baseline_comparison(runs, m["rows"], agg, integrity)
    # Traceability is checked on a rendering of this very evidence; the result
    # adds no number to the documents, so the final rendering is checked again.
    integrity["traceability"] = True
    ev["traceability"] = {"untraceable": [], "untraceable_count": 0, "checked": []}
    ev["readiness"] = _readiness(ev)
    ev["finalization"] = _finalization(ev)
    src = Path(__file__).read_text()
    bad = trace_check.check(render(ev), ev, src) + trace_check.check(render_status(ev), ev, src)
    integrity["traceability"] = not bad
    ev["traceability"] = {"untraceable": bad, "untraceable_count": len(bad),
                          "checked": ["docs/PHASE3A_REPORT.md", "docs/SYSTEM_STATUS.md"]}
    ev["readiness"] = _readiness(ev)
    ev["finalization"] = _finalization(ev)
    return ev, m


ARCHIVE_D = "p3a-sol-20261001d2"


def _finalization(ev: dict) -> dict:
    """The Phase 3A finalization checks, each read from executable evidence above."""
    runs = {r["archive"]: r for r in ev["archives"]}
    d = runs.get(ARCHIVE_D)
    checks = {
        "archive_d_included_and_provenance_verified": bool(d and d["provenance"]["verified"]),
        "archive_d_acquisition_complete": bool(d and d["run_status"] == "COMPLETE"),
        "every_included_archive_provenance_verified": all(r["provenance"]["verified"] for r in ev["archives"]),
        "lookahead_a_to_f_passed": all(r["replay"]["lookahead_all_passed"] is not False for r in ev["archives"]),
        "existing_phase2_checks_passed": all(r["phase2_checks"]["passed"] for r in ev["archives"]),
        "phase3a_integrity": all(x for k, x in ev["integrity"].items() if k != "tests_green"),
        "tests_green": ev["integrity"]["tests_green"],
        "traceability": ev["integrity"]["traceability"],
        "scope_clean": ev["integrity"]["scope_clean"],
        "cross_seed_identical": ev["cross_seed_determinism"]["identical"],
    }
    return {"checks": checks, "result": "PASS" if all(checks.values()) else "BLOCKED",
            "failed": [k for k, v in checks.items() if not v], "archive_d": ARCHIVE_D,
            "phase3b": "NOT STARTED"}


def _readiness(ev: dict) -> dict:
    a = ev["aggregates"]
    s = a["coverage_share"]
    metrics = {"funding_transfer_share": s["funding_transfer"], "liquidity_vault_delta_share": a["liquidity_vault_delta_share"],
               "creator_state_share": s["creator_state"], "holder_state_share": s["holder_state"],
               "news_share": s["news"], "social_share": s["social"], "freshness_compliance": a["freshness_compliance"],
               "provider_error_rate": a["provider_error_rate"], "multi_day_days": a["multi_day_longest_span_days"],
               "universe_tokens": a["universe_tokens"]}
    integ = {k: ev["integrity"][k] for k in rd.INTEGRITY}
    if not ev["integrity"]["tests_green"]:
        integ["evidence_integrity"] = False
    return rd.gate(integ, metrics, rd.load_config())


# ----------------------------------------------------------------- render ----
def _t(rows: list[list], head: list[str]) -> str:
    return phase2_verify._t(rows, head)


def _p(x) -> str:
    return "n/a" if x is None else f"{x:.1%}"


DIM_LABEL = {"funding_transfer": "Funding coverage", "liquidity_events": "Liquidity coverage",
             "creator_state": "Creator-state coverage", "holder_state": "Holder-state coverage",
             "news": "News coverage", "social": "Social coverage"}


def status_block(ev: dict) -> list[str]:
    a, t, i, r = ev["aggregates"], ev["tests"], ev["integrity"], ev["readiness"]
    obs = a["coverage_rows_observed"]
    n = a["coverage_rows"]
    lines = [f"* Commit: `{ev['repository']['code_version']}`", f"* Branch: `{ev['repository']['branch']}`",
             "* Working tree: clean for intel/autopsyx, intel/config, intel/migrations" if not ev["repository"]["code_version"].endswith("-dirty")
             else "* Working tree: DIRTY (evidence not final)",
             f"* Tests: Passed {t['passed']}, Failed {t['failed']}, Skipped {t['skipped']}",
             f"* Provider error rate: {_p(a['provider_error_rate'])} ({a['provider_errors']} of {a['provider_requests']} requests)",
             f"* Freshness compliance: {_p(a['freshness_compliance'])} ({a['freshness_evaluations']} governed evaluations, "
             f"{a['freshness_stale']} stale)"]
    for d, label in DIM_LABEL.items():
        extra = ""
        if d == "liquidity_events":
            extra = (f"; chain-derived add/remove in {a['liquidity_vault_delta_rows']} rows "
                     f"({_p(a['liquidity_vault_delta_share'])}), the rest is provider pool-creation metadata only")
        lines.append(f"* {label}: {obs[d]} of {n} archive-token rows OBSERVED ({_p(a['coverage_share'][d])}){extra}")
    md = ev["multi_day"]
    lines += [f"* Multi-day collection: {'PERFORMED' if md['performed'] else 'NOT PERFORMED'} "
              f"(longest span on one universe {md['longest_span_days']} days)",
              f"* Universe size: {a['universe_tokens']} distinct tokens over {a['archives']} archives",
              f"* Replay determinism: {'VERIFIED' if i['replay_determinism'] else 'FAILED'}",
              f"* Look-ahead: {'NONE DETECTED' if i['point_in_time_validity'] else 'DETECTED'}",
              f"* Traceability: {'VERIFIED' if i['traceability'] else 'FAILED'}",
              f"* Evidence integrity: {'VERIFIED' if i['evidence_integrity'] else 'FAILED'}",
              f"* Finalization gate: {ev['finalization']['result']}",
              f"* Readiness: {r['result']}"]
    return lines


def render(ev: dict) -> str:
    a, T = ev["aggregates"], ev["coverage"]["totals"]
    L = ["# Phase 3A Report: Data-Coverage Hardening", "",
         "Generated from `artifacts/phase3a/PHASE3A_EVIDENCE.json` by `intel/autopsyx/research/phase3a_verify.py`. "
         "Every number below is a value in that file; the renderer computes nothing.", "",
         "## PHASE 3A STATUS", "", *status_block(ev), ""]
    L += ["## Readiness gate", "", f"Result: **{ev['readiness']['result']}**. Rule: {ev['readiness']['rule']}.", "",
          "Reasons:", ""] + [f"* {x}" for x in ev["readiness"]["reasons"]] + [""]
    L += ["Hypothesis testing does not start: the gate is not READY." if ev["readiness"]["result"] != "READY"
          else "The gate is READY.", ""]
    fz = ev["finalization"]
    L += ["## Finalization gate", "", f"Result: **{fz['result']}**. Phase 3B: {fz['phase3b']}.", ""]
    L += [_t([[k, "pass" if v else "FAIL"] for k, v in fz["checks"].items()], ["Check", "Result"]), ""]
    inc = ev["inclusion"]
    L += ["## Archive provenance and inclusion", "", f"Rule: {inc['rule']}.", ""]
    rows = []
    for r in ev["archives"]:
        p_ = r["provenance"]
        rows.append([r["archive"], "included", p_["source"], p_["scope"], p_["runner"]["phase2_records"],
                     p_["rebuild_1"]["phase2_records"], p_["runner"]["phase3a_observations"] or "not recorded",
                     p_["rebuild_1"]["phase3a_observations"], "yes" if p_["reproducible"] else "NO",
                     {True: "yes", False: "NO", None: "n/a"}[p_["committed_matches_runner"]],
                     "yes" if p_["verified"] else "NO"])
    for x in inc["excluded"]:
        p_ = x["verification"]
        rows.append([x["archive"], x["label"], p_["source"], p_["scope"], "none", p_["rebuild_1"]["phase2_records"],
                     "none", p_["rebuild_1"]["phase3a_observations"], "yes" if p_["reproducible"] else "NO", "n/a", "NO"])
    L += [_t(rows, ["Archive", "Status", "Runner hash source", "Hash scope", "Runner phase2 hash", "Rebuilt phase2 hash",
                    "Runner phase3a hash", "Rebuilt phase3a hash", "Rebuild twice identical",
                    "Committed canonical = runner", "Verified"]), ""]
    L += ["## Per-archive funnel", "",
          "Definitions are the Phase 2 funnel's, unchanged. An archive without a replay has evaluable and classified "
          "not measured; they are not counted as failures.", ""]
    rows = []
    for r in ev["archives"]:
        for q in r["funnel"]["ratios"]:
            rows.append([r["archive"], q["step"], "n/a" if q["numerator"] is None else q["numerator"],
                         "n/a" if q["denominator"] is None else q["denominator"], _p(q["share"]),
                         q["denominator_definition"], q["not_measured_reason"] or ""])
    L += [_t(rows, ["Archive", "Step", "Numerator", "Denominator", "Share", "Denominator definition", "Not measured"]), ""]
    bc = ev["baseline_comparison"]
    L += ["## Baseline (A, B, C) versus A, B, C, D", "",
          f"Baseline: Phase 3A evidence at commit `{bc['baseline_commit']}` over {', '.join(bc['baseline_archives'])}. "
          f"Added: {', '.join(bc['added_archives']) or 'none'}.", "",
          f"Classification of the change: **{bc['classification']}** (A, B, C recomputed now reproduce the committed "
          f"baseline: {'yes' if bc['abc_reproduces_baseline'] else 'NO'}). {bc['interpretation_rule']}.", ""]
    L += [_t([[k, v["abc"], v["abcd"]] for k, v in bc["sample"].items()], ["Sample", "A, B, C", "A, B, C, D"]), ""]
    rows = [[m_["metric"], m_["baseline_abc_committed"], m_["abc_recomputed_now"], m_["abcd"],
             "n/a" if m_["difference_abcd_minus_baseline"] is None else m_["difference_abcd_minus_baseline"],
             "yes" if m_["abc_reproduces_baseline"] else "NO"] for m_ in bc["metrics"]]
    L += [_t(rows, ["Metric", "Baseline committed", "A, B, C now", "A, B, C, D", "Difference (descriptive)",
                    "A, B, C reproduces"]), ""]
    L += [_t([[k, {True: "passed", False: "FAILED", None: "n/a"}[bc["lookahead_by_archive"][k]],
               {True: "identical", False: "DIFFER", None: "n/a"}[bc["replay_identical_by_archive"][k]]]
              for k in bc["lookahead_by_archive"]], ["Archive", "Look-ahead A-F", "Two replays"]), ""]
    L += [_t([[k, "pass" if bc["baseline_integrity"].get(k) else "FAIL", "pass" if v else "FAIL"]
              for k, v in bc["current_integrity"].items()], ["Integrity", "Baseline", "Now"]), ""]
    L += ["## Existing Phase 2 checks at this commit", ""]
    rows = []
    for r in ev["archives"]:
        c = r["phase2_checks"]
        j = c["journal_audit"]
        pg_ = c["postgres_phase2"]
        rows.append([r["archive"], ", ".join(f"{k} {v}" for k, v in c["clock_and_hash_violations"].items()),
                     c["raw_audit"]["referenced_but_missing"],
                     "n/a" if j is None else f"{j['entries']} entries, {j['chain_breaks']} breaks, {j['hash_mismatches']} mismatches",
                     pg_.get("status") or ("all checks zero" if pg_.get("all_checks_zero") else "FAILED"),
                     "pass" if c["passed"] else "FAIL"])
    L += [_t(rows, ["Archive", "Clock / hash violations", "Bodies missing", "Journal", "PostgreSQL (Phase 2 load)",
                    "Result"]), ""]
    L += ["## Coverage matrix totals", "",
          f"{ev['coverage']['row_count']} rows (archive x token), {ev['coverage']['blank_cells']} blank cells. "
          f"Full matrix: `{ev['coverage']['file']}` (sha256 `{ev['coverage']['sha256']}`).", "",
          f"State rule: {ev['coverage']['state_rule']}.", ""]
    rows = []
    for d, tot in T.items():
        states = ", ".join(f"{k} {v}" for k, v in tot.items() if isinstance(v, int) and not isinstance(v, bool) and v
                           and k not in ("rows_with_vault_delta_events", "rows_with_vault_delta_requests"))
        rows.append([d, tot["positive_state"], _p(tot["positive_share"]), states or "none"])
    L += [_t(rows, ["Dimension", "Positive state", "Share", "Rows by state"]), ""]
    L += ["## Archives", ""]
    rows = []
    for r in ev["archives"]:
        rp = r["replay"]
        rows.append([r["archive"], r["family"], r["run_status"] or "not recorded", r["universe"]["source"], r["universe"]["tokens"],
                     r["exchanges"], rp["observation_count"],
                     "yes" if rp["replayable"] else "no",
                     {True: "identical", False: "DIFFER", None: "n/a"}[rp["identical"]],
                     {True: "passed", False: "FAILED", None: "n/a"}[rp["lookahead_all_passed"]],
                     r["postgres"].get("status")])
    L += [_t(rows, ["Archive", "Family", "Run", "Universe", "Tokens", "Exchanges", "Observations", "Replayable",
                    "Two replays", "Look-ahead audit", "PostgreSQL"]), ""]
    L += ["## Provider telemetry", ""]
    rows = []
    for r in ev["archives"]:
        for p, t in r["telemetry"].items():
            rows.append([r["archive"], p, t["requests"], t["errors"], _p(t["error_rate"]), t["retries_before_success"],
                         t["rate_limited_attempts"], t["backoff_s_total"], t["latency_ms"]["p50"], t["latency_ms"]["p95"],
                         t["failures_without_attempt_log"]])
    L += [_t(rows, ["Archive", "Provider", "Requests", "Errors", "Error rate", "Retries before success",
                    "Rate-limited attempts", "Backoff s", "Latency p50 ms", "Latency p95 ms",
                    "Failures without attempt log"]), ""]
    fp = ev["freshness_policy"]
    L += ["## Freshness", "", f"Policy fingerprint `{fp['fingerprint']}`, frozen: "
          f"{'yes' if fp['identical_to_frozen'] else 'NO'}. Threshold {fp['policy']['max_age_ms']} ms from "
          f"{fp['policy']['threshold_source']}, governing {', '.join(fp['policy']['governed_endpoints'])}.", ""]
    rows = []
    for r in ev["archives"]:
        for ep, f in r["freshness"]["endpoints"].items():
            rows.append([r["archive"], ep, f["evaluations"], f["age_ms"]["p50"], f["age_ms"]["max"],
                         "n/a" if f["stale"] is None else f["stale"],
                         f["compliance"] if isinstance(f["compliance"], str) else _p(f["compliance"])])
    L += [_t(rows, ["Archive", "Endpoint", "Evaluations", "Age p50 ms", "Age max ms", "Stale", "Compliance"]), ""]
    L += ["## Creator and holder state at assessment", "",
          "States come from a point-in-time view only. OBSERVED_LATER is a hindsight label computed afterwards from "
          "the full archive; it never enters an assessment.", ""]
    rows = []
    for r in ev["archives"]:
        for k, v in r["assessments"].items():
            rows.append([r["archive"], k, ", ".join(f"{a} {b}" for a, b in v["states"].items()),
                         ", ".join(f"{a} {b}" for a, b in v["hindsight"].items())])
    L += [_t(rows, ["Archive", "Kind at time", "Assessment", "Hindsight label"]), ""]
    md = ev["multi_day"]
    L += ["## Multi-day collection", "", f"Definition: {md['definition']}.", ""]
    L += [_t([[g["universe"][:16], ", ".join(g["archives"]), g["span_days"], ", ".join(g["utc_dates"])] for g in md["groups"]],
             ["Universe", "Archives", "Span days", "UTC dates"]), ""]
    s = ev["scope"]
    L += ["## Scope audit", "",
          f"* Engine paths changed since Phase 2: {s['engine_diff_since_phase2']}",
          f"* Unexplained engine changes: {s['engine_changes_unexplained_count']}",
          f"* Configuration lines removed: {s['config_lines_removed_count']}",
          f"* Forbidden terms present: {', '.join(s['forbidden_terms_present']) or 'none'}",
          f"* Phase 2 classification rule identical to frozen: {'yes' if s['phase2_rule_freeze']['identical_to_frozen'] else 'NO'}",
          f"* Hypothesis definitions unchanged: {'yes' if s['hypotheses']['phase2_hypotheses_table_unchanged'] else 'NO'}; "
          + "; ".join(f"{f} {v['diff_since_baseline']}" for f, v in s["hypotheses"]["files"].items()),
          f"* Hypotheses tested in Phase 3A: {', '.join(s['hypotheses']['tested_in_phase3a']) or 'none'}; "
          f"not tested or claimed: {', '.join(s['hypotheses']['not_claimed'])}",
          f"* Strategy logic added: {'yes' if s['strategy_logic_added'] else 'no'}", "",
          "Existing test files changed since Phase 2:", ""]
    L += [f"* `{f}`: {s['test_changes_explained'].get(f, 'UNEXPLAINED')}" for f in s["existing_tests_changed"]] + [""]
    cs = ev["cross_seed_determinism"]
    L += ["## Determinism and traceability", "",
          f"* Observations and coverage matrix recomputed in fresh processes under hash seeds "
          f"{', '.join(str(x['seed']) for x in cs['runs'])}: {'identical' if cs['identical'] else 'DIFFERENT'}",
          f"* Untraceable numbers in the documents: {ev['traceability']['untraceable_count']}", ""]
    L += ["## Remaining limitations", ""] + [f"* {x}" for x in ev["limitations"]] + [""]
    L += ["## Next permitted phase", "",
          ("None. The readiness gate is NOT_READY, so Phase 3B (hypothesis testing) does not start. The next permitted "
           "work is more Phase 3A data collection and a human decision on the thresholds in "
           "config/phase3a_readiness.toml.") if ev["readiness"]["result"] != "READY" else
          "Phase 3B, for the hypotheses whose inputs the matrix shows as covered.", ""]
    return "\n".join(L)


def render_status(ev: dict) -> str:
    L = ["# System Status", "",
         "Living status of the AUTOPSY X intelligence system, generated from "
         "`artifacts/phase3a/PHASE3A_EVIDENCE.json`. The frozen Phase 2 status is in `docs/PHASE2_SYSTEM_STATUS.md`.", "",
         "## Current phase: 3A (data-coverage hardening)", "", *status_block(ev), "",
         "## Readiness reasons", ""] + [f"* {x}" for x in ev["readiness"]["reasons"]] + [
         "", "## What runs", "",
         "* Acquisition (read-only, keyless): GeckoTerminal, DexScreener, public Solana RPC, GDELT, Reddit.",
         "* Observation contract with explicit availability states; Phase 2 records unchanged.",
         "* Deterministic point-in-time replay; PostgreSQL schema through the latest migration.",
         "* No order placement, no wallets, no strategy logic, no hypothesis testing.", "",
         "## Limitations", ""] + [f"* {x}" for x in ev["limitations"]] + [""]
    return "\n".join(L)


def write(ev: dict, m: dict, evidence: Path, coverage: Path, report: Path, status: Path) -> None:
    """Renderers read the file just written, not the in-memory dict, so the
    documents provably derive from the artifact alone."""
    evidence.parent.mkdir(parents=True, exist_ok=True)
    evidence.write_text(json.dumps(ev, indent=1, sort_keys=True) + "\n")
    coverage.write_text(json.dumps(m, indent=1, sort_keys=True) + "\n")
    frozen = json.loads(evidence.read_text())
    report.write_text(render(frozen))
    status.write_text(render_status(frozen))
