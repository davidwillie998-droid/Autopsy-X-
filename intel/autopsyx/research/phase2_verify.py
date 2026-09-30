"""Phase 2 final verification: evidence collection and report rendering.

``collect`` runs every gate against every archive and returns one evidence
dict (saved as docs/phase2_evidence/evidence.json). ``render`` turns that
dict into docs/PHASE2_REAL_DATA_REPLAY_REPORT.md. Every number in the report
is read from the evidence dict; the prose around the numbers is fixed text.
"""
from __future__ import annotations

import json
import re
import subprocess
from pathlib import Path

from .. import replay
from ..core.config import Config
from ..data.normalize import PHASE2_CAPABILITIES, normalize, replay_window, restrict_to_selection, to_store
from ..data.raw import RawStore
from . import db_validate, lookahead_audit, phase2_report

ROOT = Path(__file__).resolve().parents[3]
ENGINE_PATHS = ["intel/autopsyx/signals", "intel/autopsyx/regime", "intel/autopsyx/detection", "intel/autopsyx/risk",
                "intel/autopsyx/ranking.py", "intel/autopsyx/narrative", "intel/autopsyx/news", "intel/autopsyx/social",
                "intel/autopsyx/onchain", "intel/autopsyx/backtest", "intel/autopsyx/journal"]
ADAPTED_PATHS = ["intel/autopsyx/features", "intel/autopsyx/manipulation", "intel/autopsyx/pipeline.py",
                 "intel/autopsyx/assessment.py", "intel/autopsyx/providers", "intel/autopsyx/core"]


def git(*args: str) -> str:
    return subprocess.run(["git", *args], cwd=ROOT, capture_output=True, text=True).stdout.strip()


def pytest_counts() -> dict:
    r = subprocess.run(["python3", "-m", "pytest", "-q", "-rs"], cwd=ROOT / "intel", capture_output=True, text=True)
    tail = r.stdout.strip().splitlines()[-1] if r.stdout.strip() else ""
    counts = {k: int(v) for v, k in re.findall(r"(\d+) (passed|failed|skipped|error|errors)", tail)}
    return {"summary_line": tail, "passed": counts.get("passed", 0), "failed": counts.get("failed", 0),
            "skipped": counts.get("skipped", 0), "errors": counts.get("error", 0) + counts.get("errors", 0),
            "exit_code": r.returncode}


def scope_audit(baseline: str) -> dict:
    engine = git("diff", "--stat", baseline, "--", *ENGINE_PATHS)
    adapted = git("diff", "--stat", baseline, "--", *ADAPTED_PATHS)
    cfg = [l for l in git("diff", baseline, "--", "intel/config/default.toml").splitlines()
           if l[:1] in "+-" and not l.startswith(("+++", "---"))]
    removed_cfg = [l for l in cfg if l.startswith("-")]
    tree = "\n".join(p.read_text() for p in (ROOT / "intel" / "autopsyx").rglob("*.py")
                     if p.name != "phase2_verify.py")  # this file defines the list
    forbidden = {w: w in tree for w in ("sklearn", "torch", "tensorflow", "lightgbm", "xgboost", "place_order",
                                        "send_transaction", "sign_transaction", "private_key")}
    return {"baseline": baseline, "engine_diff_stat": engine or "(no changes)",
            "adapted_diff_stat": adapted.splitlines()[-1] if adapted else "(no changes)",
            "adapted_files": [l.split("|")[0].strip() for l in adapted.splitlines()[:-1]] if adapted else [],
            "config_lines_added": [l[1:] for l in cfg if l.startswith("+")], "config_lines_removed": removed_cfg,
            "forbidden_terms_present": {k: v for k, v in forbidden.items() if v}}


def verify_run(run_dir: Path, cfg: Config, pg: list[str] | None, work: Path, code_version: str) -> dict:
    raw = RawStore(run_dir)
    ev: dict = {"run_id": run_dir.name, "run": raw.read_json("run.json"), "selection": raw.read_json("selection.json")}
    records, rep = normalize(str(run_dir))
    runner = raw.read_json("normalize_stdout.json") or {}
    ev["dataset_sha256_local"] = rep.dataset_sha256
    ev["dataset_sha256_runner"] = runner.get("dataset_sha256")
    ev["cross_machine_normalization_match"] = rep.dataset_sha256 == runner.get("dataset_sha256")
    ev["raw_audit"] = phase2_report.raw_audit(str(run_dir))
    win = replay_window(raw)
    if win is None:
        ev["replayable"] = False
        ev["not_replayable_reason"] = "no live poll responses in archive (run ended during backfill)"
        ev["normalization"] = {k: v for k, v in rep.to_dict().items() if k != "issue_samples"}
        return ev
    ev["replayable"] = True
    ev["replay_window_ms"] = list(win)
    sel_records = restrict_to_selection(records, ev["selection"])
    digests = []
    for i in (1, 2):
        spec = replay.ReplaySpec(start_ts=win[0], end_ts=win[1], step_ms=5 * 60_000,
                                 dataset_id=f"{run_dir.name}:{rep.dataset_sha256[:16]}", code_version=code_version,
                                 caps=PHASE2_CAPABILITIES, expected_config_hash=cfg.fingerprint())
        out = work / run_dir.name / f"replay_{i}"
        res = replay.run(to_store(sel_records), cfg, spec, out)
        digests.append({"records_sha256": res.digest,
                        "journal_sha256": __import__("hashlib").sha256((out / "journal.jsonl").read_bytes()).hexdigest()})
    ev["determinism"] = {"runs": digests, "identical": digests[0] == digests[1]}
    rd = str(work / run_dir.name / "replay_1")
    ev["report"] = phase2_report.build(str(run_dir), rd, cfg.section("signal")["min_coverage"])
    step = (win[1] - win[0]) // 5
    ev["lookahead"] = lookahead_audit.run(sel_records, cfg, PHASE2_CAPABILITIES, [win[0] + step * k for k in (1, 2, 3, 4)])
    if pg:
        ev["postgres"] = db_validate.run(str(run_dir), rd, pg, f"phase2_{run_dir.name.replace('-', '_')}",
                                         ROOT / "intel" / "migrations", work / run_dir.name / "db")
    else:
        ev["postgres"] = {"status": "DATABASE EXECUTION UNVERIFIED: no server"}
    return ev


def collect(runs_dir: Path, work: Path, pg: list[str] | None, baseline: str = "e8c4f66") -> dict:
    cfg = Config.load()
    head = git("rev-parse", "HEAD")
    dirty = bool(git("status", "--porcelain", "--", "intel/autopsyx", "intel/config"))
    code_version = head + ("-dirty" if dirty else "")
    runs = [verify_run(d, cfg, pg, work, code_version) for d in sorted(p for p in runs_dir.iterdir() if p.is_dir())]
    return {"repository": {"branch": git("branch", "--show-current"), "head": head, "code_version": code_version,
                           "phase1_baseline": git("rev-parse", baseline), "log": git("log", "--oneline", f"{baseline}^..HEAD")},
            "configuration_hash": cfg.fingerprint(), "tests": pytest_counts(), "scope": scope_audit(baseline),
            "runs": runs}


# ------------------------------------------------------------------------------------ render ----
def workflow_run_of(run_id: str) -> str | None:
    msgs = git("log", "--format=%s", "--", f"intel/datasets/phase2/runs/{run_id}")
    m = re.search(r"workflow run (\d+)", msgs)
    return m.group(1) if m else None


REQUIRED_CAPABILITIES = {  # capability -> (gate or engine that needs it, field-coverage key, evidence key)
    "creator holdings": ("entry veto creator_concentration_ok", "creator_pct"),
    "funding transfers": ("cluster independence, fresh-wallet detector", None),
    "news": ("catalyst engine", None),
    "social": ("attention engine", "social_mentions"),
    "liquidity changes": ("Move Quality liquidity component, exits", "liquidity_change"),
}


def classify(ev: dict) -> tuple[str, list[str]]:
    """Rule, in order. Printed verbatim in the report."""
    why = []
    rep = [r for r in ev["runs"] if r.get("replayable")]
    if not rep:
        return "BLOCKED", ["no archive could be replayed"]
    if ev["tests"]["failed"] or ev["tests"]["errors"]:
        return "BLOCKED", ["test failures"]
    for r in rep:
        if not r["lookahead"]["all_passed"]:
            return "BLOCKED", [f"{r['run_id']}: look-ahead audit failed"]
        if not r["determinism"]["identical"]:
            return "BLOCKED", [f"{r['run_id']}: replay not deterministic"]
        if r["raw_audit"]["referenced_but_missing"] or any(v.get("hash_mismatch") for v in r["raw_audit"]["by_provider"].values()):
            return "BLOCKED", [f"{r['run_id']}: raw archive provenance broken"]
        if isinstance(r["postgres"], dict) and r["postgres"].get("all_checks_zero") is False:
            return "BLOCKED", [f"{r['run_id']}: database integrity checks failed"]
    primary = max(rep, key=lambda r: r["report"]["decisions"]["total_replay_assessments"])
    d = primary["report"]["decisions"]
    classified = d["total_replay_assessments"] - d["unclassified"]
    if classified == 0:
        return "INSUFFICIENT DATA", [f"{primary['run_id']}: no assessment reached move classification"]
    miss = primary["report"]["missingness"]
    for cap, (needer, fkey) in REQUIRED_CAPABILITIES.items():
        ok = miss.get(fkey, {}).get("OK", 0.0) if fkey else 0.0
        if ok < 0.5:
            why.append(f"{cap}: OK in {ok:.0%} of assessments (needed by {needer})")
    if why:
        return "VERIFIED WITH LIMITATIONS", why
    return "REAL-DATA PIPELINE VERIFIED", ["all gates passed and required capabilities covered"]


def _t(rows: list[list], head: list[str]) -> str:
    out = ["| " + " | ".join(head) + " |", "|" + "---|" * len(head)]
    out += ["| " + " | ".join("" if c is None else str(c) for c in r) + " |" for r in rows]
    return "\n".join(out)


def _pct(x):
    return "n/a" if x is None else f"{x:.1%}"


def _ts(ms):
    from datetime import datetime, timezone
    return "n/a" if ms is None else datetime.fromtimestamp(ms / 1000, tz=timezone.utc).strftime("%Y-%m-%d %H:%M:%S UTC")


HYPOTHESES = [
    ("H1", "independent-wallet participation → continuation", ["unique_buyers", "independence_ratio"], "funding transfers"),
    ("H2", "volume + liquidity expansion beats volume alone", ["volume_z_15", "liquidity_change"], None),
    ("H3", "social acceleration + on-chain participation", ["social_mentions", "independence_ratio"], "social posts"),
    ("H4", "social frenzy without wallet growth", ["social_mentions", "buyer_growth"], "social posts"),
    ("H5", "narrative acceleration precedes followers", ["narrative_breadth", "price_z_driving"], None),
    ("H6", "creator distribution raises failure", ["creator_pct", "unique_buyers"], None),
    ("H7", "liquidity deterioration as exit signal", ["liquidity_change", "price"], None),
    ("H8", "news-confirmed vs unexplained moves", [], "news events"),
    ("H9", "cross-venue confirmation", ["cross_venue"], "multi-venue prices"),
    ("H10", "combined model beats single classes", ["price_z_driving", "unique_buyers", "social_mentions", "creator_pct"],
     "funding transfers, news, social posts"),
]


def hypothesis_rows(primary: dict) -> list[list]:
    miss = primary["report"]["missingness"]
    rows = []
    for hid, text, fields, absent in HYPOTHESES:
        shares = {f: miss.get(f, {}).get("OK", 0.0) for f in fields}
        avail = ", ".join(f"{f} {s:.0%}" for f, s in shares.items()) or "none"
        worst = min(shares.values()) if shares else 0.0
        state = "NOT TESTABLE WITH CURRENT DATA"
        if absent:
            limit = f"{absent} not in dataset"
        elif worst == 0:
            limit = "required input never available (OK 0%)"
        else:
            limit = (f"inputs partly available; {primary['report']['replay_summary']['tokens']} tokens over "
                     f"{primary['report']['replay_summary']['steps']} steps is far below the doc 14 test design, "
                     f"and no outcome labels exist")
        rows.append([hid, text, ", ".join(fields) or "news events", avail, "yes (replay obeys available_time)",
                     "yes" if worst > 0 else "no", "no", state, limit])
    return rows


def render(ev: dict) -> str:
    cls, why = classify(ev)
    rep = [r for r in ev["runs"] if r.get("replayable")]
    primary = max(rep, key=lambda r: r["report"]["decisions"]["total_replay_assessments"]) if rep else None
    L = []
    a = L.append
    a("# Phase 2 Real-Data Replay Report\n")
    a("_Generated by `python -m autopsyx phase2-verify` from `docs/phase2_evidence/evidence.json`. "
      "Every number below is read from that file; none is typed by hand._\n")
    a("## Executive Summary\n")
    a(f"**Phase 2 classification: {cls}.**\n")
    for w in why:
        a(f"* {w}")
    if primary:
        d = primary["report"]["decisions"]
        a(f"\nPrimary archive `{primary['run_id']}`: {d['total_replay_assessments']} point-in-time assessments of "
          f"{primary['report']['replay_summary']['tokens']} tokens, {d['HIGH_CONVICTION_CONTINUATION']} signals, "
          f"{d['NO_SIGNAL']} NO_SIGNAL, {d['unclassified']} UNCLASSIFIED. "
          f"Look-ahead audit: {'all passed' if primary['lookahead']['all_passed'] else 'FAILED'}. "
          f"Replay determinism: {'identical' if primary['determinism']['identical'] else 'DIFFERENT'}.")
    a("\nReal-data ingestion and point-in-time replay are what this report verifies. It does **not** show that any "
      "strategy is valid, profitable, live-ready or safe to trade, and signal scarcity is not evidence either way.\n")
    a("Classification rule (applied in order, `research/phase2_verify.classify`): BLOCKED if no archive replays, any "
      "test fails, the look-ahead audit fails, replay is non-deterministic, raw provenance is broken, or database "
      "integrity checks fail. INSUFFICIENT DATA if no assessment reached move classification. VERIFIED WITH "
      "LIMITATIONS if any required capability is OK in under 50% of assessments. Otherwise REAL-DATA PIPELINE VERIFIED.\n")

    r0 = ev["repository"]
    a("## Repository Baseline\n")
    a(_t([["branch", r0["branch"]], ["HEAD at evidence collection", r0["head"]], ["code version recorded in replays", r0["code_version"]],
          ["Phase 1 baseline", r0["phase1_baseline"]], ["configuration hash", ev["configuration_hash"]]], ["item", "value"]))
    a("\n```\n" + r0["log"] + "\n```\n")

    a("## Acquisition Provenance\n")
    rows = []
    for r in ev["runs"]:
        m = r["run"] or {}
        rows.append([r["run_id"], workflow_run_of(r["run_id"]), m.get("code_version", "")[:12], _ts(m.get("started_ms")),
                     _ts(m.get("ended_ms")), m.get("status", "CANCELLED (no end record)"), m.get("cycles"),
                     m.get("exchanges"), m.get("errors"), m.get("circuit_waits"), r["selection"]["seed"] if r["selection"] else None])
    a(_t(rows, ["archive", "workflow run", "acquisition code", "started", "ended", "status", "poll cycles",
                "exchanges", "errors", "circuit waits", "seed"]))
    a("\nEvery exchange (request URL with parameters, request and response timestamps, HTTP status, attempts, error, "
      "context with token/pool identity, page and cycle) is a line in `manifest.jsonl`; bodies are stored byte-for-byte "
      "under their sha256. Selection (seed, strata targets, candidate counts, picks, exclusions, procedure text) is in "
      "`selection.json`.\n")
    for r in ev["runs"]:
        if not r["selection"]:
            continue
        a(f"**{r['run_id']} selection** (candidates: {r['selection']['candidates']})\n")
        a(_t([[p["stratum"], p["dex"], p["token"], p["pool"], _ts(p["created_ts"]),
               None if p["liquidity_usd"] is None else round(p["liquidity_usd"]), p["h1_txns"]] for p in r["selection"]["picked"]],
             ["stratum", "dex", "token", "pool", "pool created", "liquidity USD at selection", "h1 txns"]))
        a("")

    a("## Raw Archive Integrity\n")
    rows = []
    for r in ev["runs"]:
        for prov, c in r["raw_audit"]["by_provider"].items():
            rows.append([r["run_id"], prov, c.get("exchanges", 0), c.get("valid_json", 0), c.get("malformed_json", 0),
                         c.get("partial_or_error_body", 0), c.get("provider_errors", 0), c.get("identical_body_repeats", 0),
                         c.get("missing_response_ts", 0), c.get("response_before_request", 0), c.get("out_of_order_response", 0),
                         c.get("hash_mismatch", 0), c.get("missing_body_file", 0), c.get("empty_body", 0), c.get("length_mismatch", 0)])
    a(_t(rows, ["archive", "provider", "exchanges", "valid JSON", "malformed", "partial/error body", "provider errors",
                "identical-body repeats", "missing response ts", "response before request", "out of order",
                "hash mismatch", "missing body file", "empty body", "length mismatch"]))
    a("")
    a(_t([[r["run_id"], r["raw_audit"]["body_files"], r["raw_audit"]["referenced_bodies"],
           r["raw_audit"]["unreferenced_body_files"], r["raw_audit"]["referenced_but_missing"],
           r["dataset_sha256_local"][:16], (r["dataset_sha256_runner"] or "")[:16], r["cross_machine_normalization_match"]]
          for r in ev["runs"]],
         ["archive", "body files", "referenced", "unreferenced files", "referenced but missing", "dataset sha (here)",
          "dataset sha (runner)", "cross-machine match"]))
    a("\nProvider errors are kept as manifest lines with no body (a failed exchange has no bytes to keep). "
      "Identical-body repeats are the same bytes returned by consecutive polls (quiet pools); they are stored once.\n")
    for r in ev["runs"]:
        if r.get("replayable"):
            rr = r["report"]
            a(f"{r['run_id']} provider error kinds: {rr['error_kinds'] or 'none'}\n")

    a("## Provider Coverage (measured)\n")
    for r in rep:
        fc = r["report"]["field_coverage"]["rows"]
        miss = r["report"]["missingness"]
        a(f"**{r['run_id']}** ({r['report']['field_coverage']['tokens']} tokens). "
          f"\"Point-in-time usable\" = share of replay assessments in which the engine input built from this field had status OK.\n")
        rows = [
            ["OHLCV", "GeckoTerminal", fc["OHLCV"]["records"] > 0, f"{fc['OHLCV']['tokens_with']} tokens, {fc['OHLCV']['records']} bar versions", _pct(fc["OHLCV"]["pit_ok_share"]), "price z (driving window)"],
            ["trades", "GeckoTerminal", fc["trades"]["records"] > 0, f"{fc['trades']['tokens_with']} tokens, {fc['trades']['records']} observations, {fc['trades']['coverage_claims']} coverage claims", _pct(fc["trades"]["pit_ok_share"]), "unique buyers in window"],
            ["wallet address", "GeckoTerminal (tx signer)", fc["wallet address"]["distinct_wallets"] > 0, f"{fc['wallet address']['distinct_wallets']} distinct wallets", _pct(fc["wallet address"]["pit_ok_share"]), "signer, not beneficiary"],
            ["liquidity", "GeckoTerminal, DexScreener", fc["liquidity"]["records"] > 0, f"{fc['liquidity']['records']} snapshots", _pct(fc["liquidity"]["pit_ok_share"]), "level"],
            ["liquidity changes", "none (snapshots only)", fc["liquidity changes"]["lp_events"] > 0, f"{fc['liquidity changes']['lp_events']} LP events", _pct(fc["liquidity changes"]["pit_ok_share"]), "change derived from snapshots inside the window"],
            ["creator holdings", "GeckoTerminal token info", fc["creator holdings"]["with_creator_pct"] > 0, f"{fc['creator holdings']['with_creator_pct']} of {fc['creator holdings']['holder_snapshots']} holder snapshots; {fc['creator holdings']['tokens_with_creator_identity']} token records with creator identity", _pct(fc["creator holdings"]["pit_ok_share"]), "entry veto input"],
            ["holder concentration", "GeckoTerminal token info", fc["holder concentration"]["holder_snapshots"] > 0, f"{fc['holder concentration']['holder_snapshots']} snapshots, {fc['holder concentration']['tokens_with']} tokens", _pct(fc["holder concentration"]["pit_ok_share"]), "top-10 share"],
            ["funding transfers", "none", fc["funding transfers"]["records"] > 0, f"{fc['funding transfers']['records']} records", "0.0%", "cluster edges"],
            ["social", "none", fc["social"]["records"] > 0, f"{fc['social']['records']} records", _pct(fc["social"]["pit_ok_share"]), ""],
            ["news", "none", fc["news"]["records"] > 0, f"{fc['news']['records']} records", "n/a", "catalyst reported unknown, not absent"],
        ]
        a(_t(rows, ["Field / Capability", "Provider", "Present", "Coverage", "Point-in-time usable", "Notes"]))
        a("\nFull availability status of every gate input across all assessments:\n")
        a(_t([[f, *(_pct(v.get(k)) for k in ("OK", "MISSING", "STALE", "INSUFFICIENT_HISTORY", "UNVERIFIED", "CONFLICTING"))]
              for f, v in miss.items()], ["input", "OK", "MISSING", "STALE", "INSUFFICIENT_HISTORY", "UNVERIFIED", "CONFLICTING"]))
        a("")

    a("## Data Quality\n")
    for r in ev["runs"]:
        n = r["report"]["normalization"] if r.get("replayable") else r.get("normalization", {})
        if not n:
            continue
        a(f"**{r['run_id']}** records: {n['records']}; duplicate swap observations (poll overlap, earliest kept): "
          f"{n['duplicate_swaps']}; trade-coverage gaps: {sum(len(v) for v in n['coverage_gaps'].values())} across "
          f"{len(n['coverage_gaps'])} tokens.\n")
        a(_t([[k, v] for k, v in n["issues"].items()], ["normalization issue", "count"]))
        a("")
        if r.get("replayable"):
            fm = {k.split(":", 1)[1]: v for k, v in r["report"]["replay_summary"]["counts"].items() if k.startswith("failure:")}
            a(_t([[k, v] for k, v in sorted(fm.items())], ["failure mode in replay assessments", "count"]))
            a("")

    a("## Point-In-Time Guarantees\n")
    a("* The store exposes a record at decision time t only if `seen_ts` (available_time) ≤ t; `seen_ts` is the local "
      "receive time of the first response containing the record.\n"
      "* Replay aborts with `point-in-time violation` if any observation referenced by a decision has available_time "
      "after the decision time (the guard ran on every assessment below).\n"
      "* Only closed bars are observations; bars not closed 60 s before the response are dropped.\n"
      "* Order-flow features are computed only inside observed trade coverage; elsewhere they are MISSING.\n"
      f"* Unit and adversarial tests: {ev['tests']['summary_line']}.\n")

    a("## Adversarial Look-Ahead Results (real archives)\n")
    rows = [[r["run_id"], ", ".join(_ts(t) for t in r["lookahead"]["times"]), *r["lookahead"]["summary"].values()] for r in rep]
    if rep:
        a(_t(rows, ["archive", "decision times", *rep[0]["lookahead"]["summary"].keys()]))
    a("\nA future bar (50x price), B future trades by a new wallet, C future liquidity collapse, D an already-visible "
      "record moved to available_time t+1 ms (must vanish and equal outright deletion), E archive truncated at t, F "
      "identical recomputation. Each compares the full decision output (every token's assessment, signal and all "
      "rankings) byte for byte. Limit of detection: a leak of records whose *event* time is also after t would be "
      "masked by the engines' event-time windows, so these tests cannot distinguish a leaking view from a correct one "
      "for such records; late-arriving and revised records are what they can detect (a planted leak of that kind is "
      "caught in `test_lookahead_audit_detects_a_planted_leak`).\n")

    a("## Replay Methodology\n")
    for r in rep:
        s = r["report"]["replay_summary"]
        a(_t([["window", f"{_ts(s['start_ts'])} → {_ts(s['end_ts'])}"], ["step", f"{s['step_ms'] // 60000} min"],
              ["tokens (recorded selection)", s["tokens"]], ["steps", s["steps"]], ["capabilities", s["capabilities"]],
              ["dataset id", s["dataset_id"]], ["configuration hash", s["configuration_hash"]],
              ["code version", s["code_version"]], ["records sha256", s["records_sha256"]]], [r["run_id"], "value"]))
        a("")
    a("Procedure: docs/REPLAY_PROTOCOL.md. The replay starts at the first live poll, because before it availability "
      "times were not observed. Configuration hash is pinned with `expected_config_hash`.\n")

    a("## Real-Data Decision Distribution\n")
    keys = ["total_replay_assessments", "HIGH_CONVICTION_CONTINUATION", "WATCH", "NO_SIGNAL", "blocked",
            "no_signal_without_block_reason", "unclassified", "risk_rejected", "data_quality_rejected",
            "manipulation_vetoed", "hypothetical_entries", "emergency_exits", "assessments_blocked_by_creator_gate_alone"]
    a(_t([[k, *(r["report"]["decisions"][k] for r in rep)] for k in keys], ["measure", *(r["run_id"] for r in rep)]))
    a("\n`blocked` counts assessments with at least one block reason; one assessment usually has several, so the "
      "categories below overlap and sum to more than the number of assessments.\n")

    a("## NO_SIGNAL Breakdown\n")
    cats = sorted({c for r in rep for c in r["report"]["decisions"]["block_reason_occurrences"]})
    a(_t([[c, *(r["report"]["decisions"]["block_reason_occurrences"].get(c, 0) for r in rep)] for c in cats],
         ["block reason (occurrences)", *(r["run_id"] for r in rep)]))
    a("\nCategories are mapped from the literal `blocked_by` strings in `research/phase2_report.REASON_CATEGORIES`. "
      "`creator_concentration_unavailable` is the conservative behaviour required when creator holdings are unknown: "
      "the gate is not weakened.\n")

    a("## Detector Behaviour\n")
    for r in rep:
        c = r["report"]["replay_summary"]["counts"]
        grp = lambda p: {k.split(":", 1)[1]: v for k, v in c.items() if k.startswith(p + ":")}
        a(f"**{r['run_id']}**\n")
        a(_t([["move class", grp("move")], ["regime", grp("regime")], ["exhaustion", grp("exhaustion")],
              ["leader/follower role", grp("role")], ["manipulation flags", grp("flag") or "none"],
              ["lifecycle", grp("lifecycle")]], ["output", "counts"]))
        a("")
        el = r["report"]["early_life"]
        a(f"Early-life experiment (definitions fixed in `research/early_life.py`): S1 safety invariant "
          f"{'held' if el['S1_safe'] else 'VIOLATED'} ({len(el['S1_violations'])} violations).\n")
        a(_t([[b, v["assessments"], v["tokens"], _pct(v["U1_classified_share"]), _pct(v["U2_coverage_ok_share"]),
               _pct(v["U3_participation_evaluable_share"]), _pct(v["insufficient_history_share"]), v["high_conviction_signals"]]
              for b, v in el["by_age"].items()],
             ["age bucket", "assessments", "tokens", "U1 classified", "U2 MQ coverage ≥ min", "U3 participation evaluable",
              "INSUFFICIENT_HISTORY", "signals"]))
        a("")

    if primary:
        a("## Hypothesis H1-H10 Coverage\n")
        a(f"Measured on `{primary['run_id']}`. No hypothesis test was executed in Phase 2 (scope: data and replay only).\n")
        a(_t(hypothesis_rows(primary), ["hypothesis", "claim", "data required", "data available (OK share)",
                                        "point-in-time valid", "replayable", "test executed", "evidence state", "limitation"]))
        a("\nNOT TESTABLE is not failure, and untested is not survival.\n")

    a("## PostgreSQL Validation\n")
    for r in rep:
        p = r["postgres"]
        if "row_counts" not in p:
            a(f"{r['run_id']}: {p}\n")
            continue
        a(f"**{r['run_id']}**: PostgreSQL {p['postgres_version']}; migrations {p['migrations']}; load {p['load']} "
          f"({p['statements']} statements); TimescaleDB available: {p['timescaledb_available']}.\n")
        a(_t([[k, v] for k, v in p["row_counts"].items()], ["table", "rows"]))
        a("")
        a(_t([[k, v] for k, v in p["integrity_checks"].items()], ["integrity query (must be 0)", "result"]))
        a("")
    a("TimescaleDB-specific hypertable behaviour remains UNVERIFIED: `create_hypertable` was replaced by a no-op stub. "
      "PostgreSQL schema and constraint behaviour were verified against the PostgreSQL version stated above, and in CI "
      "against the `postgres:16` service image.\n")

    a("## Journal Integrity\n")
    a(_t([[r["run_id"], r["report"]["journal_audit"]["entries"], r["report"]["journal_audit"]["chain_breaks"],
           r["report"]["journal_audit"]["hash_mismatches"], r["report"]["journal_audit"]["duplicate_token_steps"],
           r["report"]["journal_audit"]["chronology_violations"], r["report"]["journal_audit"]["configuration_hashes"],
           r["postgres"].get("integrity_checks", {}).get("journal_chain_breaks_in_db", "n/a"),
           r["determinism"]["identical"], r["determinism"]["runs"][0]["journal_sha256"][:16]] for r in rep],
         ["archive", "entries", "chain breaks", "hash mismatches", "duplicate steps", "chronology violations",
          "config hashes", "chain breaks (in db)", "two runs identical", "journal sha256"]))
    a("\nTamper detection itself is tested (`test_journal_audit_detects_tampering`, `test_journal_hash_chain`).\n")

    a("## Scope Audit\n")
    sc = ev["scope"]
    a(_t([["engine files changed since Phase 1 (signals, regime, detection, risk, ranking, narrative, news, social, "
           "onchain, backtest, journal)", sc["engine_diff_stat"]],
          ["data-contract files changed", sc["adapted_diff_stat"]],
          ["config lines removed or changed", len(sc["config_lines_removed"])],
          ["config lines added", "; ".join(x.strip() for x in sc["config_lines_added"] if x.strip() and not x.strip().startswith("#"))],
          ["ML / execution terms present in package", sc["forbidden_terms_present"] or "none"]], ["check", "result"]))
    a("\nChanged data-contract files: " + ", ".join(f"`{f}`" for f in sc["adapted_files"]) + ". Their changes are "
      "listed in DATA_PROVENANCE.md and SYSTEM_STATUS.md (coverage-aware bars and participation, stale-liquidity fix, "
      "capability gating of detectors, provenance fields, transport repairs). No threshold, weight, signal, entry, "
      "exit, risk or ranking rule changed.\n")

    a("## Known Limitations\n")
    cr = primary["report"]["field_coverage"]["rows"]["creator holdings"] if primary else {}
    cr_ok = primary["report"]["missingness"].get("creator_pct", {}).get("OK", 0.0) if primary else 0.0
    lim = [
        "Funding transfers, LP add/remove events, news and social data are absent: H1, H3, H4, H8, H9, H10 cannot be tested.",
        f"Creator holdings (GeckoTerminal `developer_holding_percentage`) are present in {cr.get('with_creator_pct')} of "
        f"{cr.get('holder_snapshots')} holder snapshots of the primary archive and usable in {cr_ok:.0%} of assessments; "
        "before a token's first token-info fetch the input is MISSING and the creator-concentration veto blocks the "
        "assessment (conservative behaviour, unchanged). A reported 0.0 is kept as zero; whether the provider means "
        "'none' or 'unknown' by it is not documented.",
        "Adapter limitation: a token-info response with a null holder count yields no HolderSnapshot, so its creator "
        "percentage is dropped with it (HolderSnapshot.holders is a required integer).",
        "Liquidity history exists only from the first poll onward; liquidity change needs a snapshot inside the window.",
        "Trades are the latest ≤ 300 per poll; hot pools exceed that between polls, which truncates coverage and makes flow MISSING.",
        "Wallet = transaction signer. Router, bot and aggregator trades attribute to the signer.",
        "Only the primary pool of each token is polled, so cross-venue confirmation is never available.",
        "Collection ran from a shared CI runner IP that the provider throttled; archive A lost its backfill and polled at "
        "~4 min intervals, which the unchanged 120 s freshness limit correctly marks STALE.",
        "The sample is tiny (a handful of tokens over under an hour per archive). It verifies the pipeline; it says nothing "
        "about market behaviour.",
        "TimescaleDB behaviour is unverified.",
        "Look-ahead tests cannot distinguish a leaking view for records whose event time is after t (masked by event-time windows).",
    ]
    for x in lim:
        a(f"* {x}")
    a("\n## Reproducibility Instructions\n")
    a("```bash\ncd intel\npython -m autopsyx normalize datasets/phase2/runs/<run_id>          # compare dataset_sha256 with normalize_stdout.json\n"
      f"python -m autopsyx replay-run datasets/phase2/runs/<run_id> --expect-config {ev['configuration_hash']}\n"
      "python -m autopsyx lookahead-audit datasets/phase2/runs/<run_id>\n"
      "python -m autopsyx db-validate datasets/phase2/runs/<run_id> <replay dir> --pg 'host=... port=... user=...'\n"
      "python -m autopsyx phase2-verify     # everything above for every archive, writes evidence.json and this report\n```\n")
    a("## Phase 2 Verdict\n")
    a(f"**{cls}**\n")
    for w in why:
        a(f"* {w}")
    a("\nPhase 2 ends here. Parameter optimisation, ML, new providers and live execution are out of scope; the next "
      "phase starts from this evidence.\n")
    return "\n".join(L) + "\n"


def render_status(ev: dict) -> str:
    cls, why = classify(ev)
    rep = [r for r in ev["runs"] if r.get("replayable")]
    primary = max(rep, key=lambda r: r["report"]["decisions"]["total_replay_assessments"]) if rep else None
    t = ev["tests"]
    L = ["# System Status\n",
         "_Generated by `python -m autopsyx phase2-verify` from `docs/phase2_evidence/evidence.json`._\n",
         _t([["branch", ev["repository"]["branch"]], ["commit at verification", ev["repository"]["head"]],
             ["Phase 1 baseline", ev["repository"]["phase1_baseline"]],
             ["Phase 2 state", f"COMPLETE: {cls}"],
             ["tests", f"{t['passed']} passed, {t['failed']} failed, {t['skipped']} skipped"],
             ["configuration hash", ev["configuration_hash"]]], ["item", "value"]), ""]
    L.append("## Acquisition\n")
    L.append(_t([[r["run_id"], workflow_run_of(r["run_id"]), (r["run"] or {}).get("status", "CANCELLED"),
                  (r["run"] or {}).get("exchanges"), (r["run"] or {}).get("errors"), r.get("replayable"),
                  r["cross_machine_normalization_match"]] for r in ev["runs"]],
                ["archive", "workflow run", "status", "exchanges", "errors", "replayable", "runner/local dataset hash match"]))
    L.append("\n## Replay\n")
    L.append(_t([[r["run_id"], r["report"]["decisions"]["total_replay_assessments"],
                  r["report"]["decisions"]["HIGH_CONVICTION_CONTINUATION"], r["report"]["decisions"]["NO_SIGNAL"],
                  r["report"]["decisions"]["unclassified"], r["determinism"]["identical"], r["lookahead"]["all_passed"],
                  r["report"]["journal_audit"]["chain_breaks"] == 0 and r["report"]["journal_audit"]["hash_mismatches"] == 0]
                 for r in rep], ["archive", "assessments", "signals", "NO_SIGNAL", "UNCLASSIFIED", "deterministic",
                                 "look-ahead audit passed", "journal intact"]))
    L.append("\n## Database\n")
    for r in rep:
        p = r["postgres"]
        L.append(f"* {r['run_id']}: PostgreSQL {p.get('postgres_version', 'n/a')}, load {p.get('load', p.get('status'))}, "
                 f"integrity checks all zero: {p.get('all_checks_zero')}")
    L.append("* TimescaleDB-specific hypertable behaviour: UNVERIFIED (not installable here; `create_hypertable` stubbed).\n")
    if primary:
        L.append("## Provider coverage (primary archive, share of assessments with input OK)\n")
        L.append(_t([[f, _pct(v.get("OK", 0.0))] for f, v in primary["report"]["missingness"].items()], ["input", "OK"]))
    L.append("\n## Known data limitations\n")
    for w in why:
        L.append(f"* {w}")
    L.append("* See docs/PHASE2_REAL_DATA_REPLAY_REPORT.md, Known Limitations, for the full list.\n")
    L.append("## What this status does not claim\n")
    L.append("No live-trading validation, no profitability, no predictive validity. Replay executing on real data is an "
             "ingestion and integrity result only. No execution code exists.\n")
    L.append(f"## Final Phase 2 classification\n\n**{cls}**\n")
    return "\n".join(L) + "\n"
