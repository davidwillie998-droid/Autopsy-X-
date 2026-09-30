"""Phase 2 final verification: evidence collection and report rendering.

``collect`` runs every gate against every archive and returns one evidence
dict (saved as artifacts/phase2/PHASE2_EVIDENCE.json). ``render`` turns that
dict into docs/PHASE2_REPORT.md. Every number in the report
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
    tail = re.sub(r" in [0-9.]+s.*$", "", tail)  # wall-clock duration would make the evidence nondeterministic
    return {"summary_line": tail, "passed": counts.get("passed", 0), "failed": counts.get("failed", 0),
            "skipped": counts.get("skipped", 0), "errors": counts.get("error", 0) + counts.get("errors", 0),
            "exit_code": r.returncode}


# Every change to an engine file since Phase 1, with the reason. The scope audit fails if the
# diff contains anything else.
ENGINE_CHANGES_EXPLAINED = {
    "intel/autopsyx/signals/entry.py": {
        "reason": "blocked_by was built by iterating a set of FailureMode values; its order followed the per-process "
                  "string-hash seed, so journals differed between processes. Sorted. No decision, threshold or gate "
                  "changed (regression: test_replay_is_identical_across_processes_with_different_hash_seeds).",
        "removed": ["    blocked: list[str] = [f.value for f in a.failures & BLOCKING]"],
        "added": ["    # sorted: set iteration order follows per-process string hashing, which made output differ between runs",
                  "    blocked: list[str] = sorted(f.value for f in a.failures & BLOCKING)"],
    },
}


def scope_audit(baseline: str) -> dict:
    engine = git("diff", "--stat", baseline, "--", *ENGINE_PATHS)
    engine_lines: dict[str, dict[str, list[str]]] = {}
    cur = None
    for l in git("diff", "-U0", baseline, "--", *ENGINE_PATHS).splitlines():
        if l.startswith("+++ b/"):
            cur = l[6:]
            engine_lines[cur] = {"removed": [], "added": []}
        elif cur and l.startswith("-") and not l.startswith("---"):
            engine_lines[cur]["removed"].append(l[1:])
        elif cur and l.startswith("+") and not l.startswith("+++"):
            engine_lines[cur]["added"].append(l[1:])
    unexplained = {f: d for f, d in engine_lines.items()
                   if f not in ENGINE_CHANGES_EXPLAINED
                   or d != {k: ENGINE_CHANGES_EXPLAINED[f][k] for k in ("removed", "added")}}
    adapted = git("diff", "--stat", baseline, "--", *ADAPTED_PATHS)
    cfg = [l for l in git("diff", baseline, "--", "intel/config/default.toml").splitlines()
           if l[:1] in "+-" and not l.startswith(("+++", "---"))]
    removed_cfg = [l for l in cfg if l.startswith("-")]
    tree = "\n".join(p.read_text() for p in (ROOT / "intel" / "autopsyx").rglob("*.py")
                     if p.name != "phase2_verify.py")  # this file defines the list
    forbidden = {w: w in tree for w in ("sklearn", "torch", "tensorflow", "lightgbm", "xgboost", "place_order",
                                        "send_transaction", "sign_transaction", "private_key")}
    return {"baseline": baseline, "engine_diff_stat": engine or "(no changes)",
            "engine_changed_lines": engine_lines, "engine_changes_explained": ENGINE_CHANGES_EXPLAINED,
            "engine_changes_unexplained": unexplained,
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
        ev["funnel"] = funnel(raw, records, restrict_to_selection(records, ev["selection"]), None)
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
    ev["funnel"] = funnel(raw, records, sel_records, Path(rd) / "journal.jsonl")
    ev["coverage_adjusted"] = coverage_adjusted(Path(rd) / "journal.jsonl")
    step = (win[1] - win[0]) // 5
    ev["lookahead"] = lookahead_audit.run(sel_records, cfg, PHASE2_CAPABILITIES, [win[0] + step * k for k in (1, 2, 3, 4)])
    if pg:
        ev["postgres"] = db_validate.run(str(run_dir), rd, pg, f"phase2_{run_dir.name.replace('-', '_')}",
                                         ROOT / "intel" / "migrations", work / run_dir.name / "db")
    else:
        ev["postgres"] = {"status": "DATABASE EXECUTION UNVERIFIED: no server"}
    return ev


def funnel(raw: RawStore, all_records: list, sel_records: list, journal_path: Path | None) -> dict:
    """discovered -> attempted -> successful -> evaluable -> classified, per token."""
    from collections import defaultdict
    sel = raw.read_json("selection.json") or {}
    picked = [p["token"] for p in sel.get("picked", [])]
    discovered = sorted({r.ref.key.split(":", 1)[1] for r in all_records if type(r).__name__ == "TokenMeta"})
    ok_by = defaultdict(lambda: defaultdict(int))
    fail_by = defaultdict(lambda: defaultdict(int))
    for e in raw.entries():
        tok = e.context.get("token")
        if tok is None:
            continue
        (fail_by if e.error or e.raw_id is None else ok_by)[tok][e.endpoint + (".backfill" if "page" in e.context else "")] += 1
    bars = defaultdict(list)
    holders = defaultdict(int)
    creator = defaultdict(int)
    for r in sel_records:
        n = type(r).__name__
        if n == "ProviderBar":
            bars[r.token].append(r.ts)
        elif n == "HolderSnapshot":
            holders[r.token] += 1
            creator[r.token] += r.creator_pct is not None
    evaluable, classified = set(), set()
    steps = defaultdict(int)
    dq = defaultdict(lambda: defaultdict(int))
    if journal_path is not None and journal_path.exists():
        for l in journal_path.read_text().splitlines():
            if not l.strip():
                continue
            j = json.loads(l)["payload"]
            tok = j["token"].split(":", 1)[1]
            steps[tok] += 1
            for f in j["data_quality"]:
                dq[tok][f] += 1
            if j["feature_status"]["price"] == "OK" and "NO_DATA" not in j["data_quality"]:
                evaluable.add(tok)
            if j["move_class"] != "UNCLASSIFIED":
                classified.add(tok)
    successful = [t for t in picked if ok_by[t].get("gt.ohlcv", 0) + ok_by[t].get("gt.ohlcv.backfill", 0) > 0
                  and ok_by[t].get("gt.trades", 0) > 0]
    per_token = []
    for t in picked:
        ts = sorted(bars[t])
        per_token.append({
            "token": t, "stratum": next(p["stratum"] for p in sel["picked"] if p["token"] == t),
            "ok_responses": dict(sorted(ok_by[t].items())), "failed_responses": dict(sorted(fail_by[t].items())),
            "backfill_ok": ok_by[t].get("gt.ohlcv.backfill", 0), "backfill_failed": fail_by[t].get("gt.ohlcv.backfill", 0),
            "bar_versions": len(ts), "distinct_bars": len(set(ts)),
            "bar_history_minutes": (ts[-1] - ts[0]) // 60_000 + 1 if ts else 0,
            "holder_snapshots": holders[t], "holder_snapshots_with_creator_pct": creator[t],
            "replay_steps": steps[t], "successful": t in successful, "evaluable": t in evaluable,
            "classified": t in classified, "data_quality_counts": dict(sorted(dq[t].items())),
            "reduction_reason": (None if t in classified else
                                 "no successful OHLCV and trades response" if t not in successful else
                                 "no replay step with an OK price" if t not in evaluable else
                                 "move never classifiable: " + (", ".join(f"{k} {v}/{steps[t]}" for k, v in sorted(dq[t].items()))
                                                                  or "fewer historical windows than min_baseline_samples"))})
    return {"discovered": len(discovered), "attempted": len(picked), "successful": len(successful),
            "evaluable": len(evaluable), "classified": len(classified),
            "unclassified_or_incomplete": len(picked) - len(classified),
            "definitions": {
                "discovered": "distinct tokens described by any discovery or poll response",
                "attempted": "tokens picked by the seeded stratified selection and polled",
                "successful": "attempted tokens with at least one successful OHLCV and one successful trades response",
                "evaluable": "tokens with at least one replay assessment whose price input was OK and not NO_DATA",
                "classified": "tokens with at least one replay assessment whose move class was not UNCLASSIFIED"},
            "per_token": per_token}


def coverage_adjusted(journal_path: Path) -> dict:
    """Rates computed over the assessments that could be evaluated, next to the raw totals."""
    js = [json.loads(l)["payload"] for l in journal_path.read_text().splitlines() if l.strip()]
    ev = [j for j in js if j["feature_status"]["price"] == "OK" and "NO_DATA" not in j["data_quality"]]
    cls = [j for j in ev if j["move_class"] != "UNCLASSIFIED"]
    fresh = [j for j in ev if "STALE_DATA" not in j["data_quality"]]
    reach_creator = [j for j in js if "creator_concentration_ok" in j["conditions"]]
    creator_unknown = [j for j in reach_creator if j["conditions"]["creator_concentration_ok"] is None]
    def rate(num, den, num_def, den_def):
        return {"numerator": len(num), "denominator": len(den), "value": (len(num) / len(den)) if den else None,
                "numerator_definition": num_def, "denominator_definition": den_def, "source": "replay journal"}
    return {"assessments": len(js), "evaluable_assessments": len(ev), "classified_assessments": len(cls),
            "fresh_evaluable_assessments": len(fresh),
            "evaluable_share_of_all": rate(ev, js, "evaluable assessments", "all replay assessments"),
            "classified_share_of_all": rate(cls, js, "classified assessments", "all replay assessments"),
            "classified_share_of_evaluable": rate(cls, ev, "classified assessments", "evaluable assessments"),
            "fresh_share_of_evaluable": rate(fresh, ev, "evaluable assessments without STALE_DATA", "evaluable assessments"),
            "signals_per_evaluable": rate([j for j in ev if j["signal"] != "NO_SIGNAL"], ev,
                                          "evaluable assessments with a signal", "evaluable assessments"),
            "creator_input_unknown_share": rate(creator_unknown, reach_creator, "assessments with creator input unknown",
                                                "all assessments (every assessment evaluates the creator condition)"),
            "required_data_unavailable_assessments": sum(1 for j in js if any(b.startswith("critical input missing")
                                                                             for b in j["blocked_by"]))}


def rule_fingerprint(source: str) -> str:
    """sha256 over the text of classify(), CLASSIFICATION_RULE, REQUIRED_OK_SHARE and REQUIRED_CAPABILITIES."""
    import hashlib
    parts = []
    # anchored at line start: these strings also occur, quoted, inside this function
    for start, end in (("\nREQUIRED_CAPABILITIES = {", "\n}\n"), ("\nCLASSIFICATION_RULE = [", "\n]\n"),
                       ("\nREQUIRED_OK_SHARE = ", "\n"), ("\ndef classify(ev: dict)", "\n\n\n")):
        i = source.index(start)
        parts.append(source[i: source.index(end, i) + len(end)])
    return hashlib.sha256("".join(parts).encode()).hexdigest()


def rule_freeze(runs_dir: Path) -> dict:
    """The rule in force is compared with the rule as committed before the newest archive landed."""
    rel = "intel/autopsyx/research/phase2_verify.py"
    newest = sorted(p.name for p in runs_dir.iterdir() if p.is_dir())[-1]
    landed = git("log", "--format=%H", "--diff-filter=A", "-1", "--", f"intel/datasets/phase2/runs/{newest}/run.json")
    frozen_commit = git("rev-parse", f"{landed}^") if landed else None
    current = rule_fingerprint(Path(__file__).read_text())
    frozen_src = git("show", f"{frozen_commit}:{rel}") if frozen_commit else ""
    frozen = rule_fingerprint(frozen_src) if frozen_src else None
    return {"newest_archive": newest, "newest_archive_commit": landed, "frozen_commit": frozen_commit,
            "frozen_rule_sha256": frozen, "current_rule_sha256": current, "identical_to_frozen": current == frozen,
            "missing_evidence_treatment": "a capability absent from the dataset scores OK share 0.0; an archive "
                                          "without live polls is not replayable and cannot satisfy rules 3-6",
            "acquisition_incomplete_treatment": "non-replayable archives are reported and excluded from rules 3-5; "
                                                "rule 1 blocks if none is replayable"}


def collect(runs_dir: Path, work: Path, pg: list[str] | None, baseline: str = "e8c4f66") -> dict:
    cfg = Config.load()
    tests = pytest_counts()
    head = git("rev-parse", "HEAD")
    dirty = bool(git("status", "--porcelain", "--", "intel/autopsyx", "intel/config"))
    code_version = head + ("-dirty" if dirty else "")
    runs = [verify_run(d, cfg, pg, work, code_version) for d in sorted(p for p in runs_dir.iterdir() if p.is_dir())]
    for r in runs:
        c, why, _ = classify({"runs": [r], "tests": tests})
        r["archive_classification"] = {"classification": c, "reasons": why}
    ev = {"repository": {"branch": git("branch", "--show-current"), "head": head, "code_version": code_version,
                           "phase1_baseline": git("rev-parse", baseline), "log": git("log", "--oneline", f"{baseline}^..HEAD")},
            "configuration_hash": cfg.fingerprint(), "tests": tests, "scope": scope_audit(baseline),
            "runs": runs}
    ev["rule_freeze"] = rule_freeze(runs_dir)
    if not ev["rule_freeze"]["identical_to_frozen"]:
        raise RuntimeError("classification rule differs from the frozen rule; refusing to classify")
    c, why, inputs = classify(ev)
    ev["classification"] = {"rule": CLASSIFICATION_RULE, "result": c, "reasons": why, "inputs": inputs}
    return ev


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


CLASSIFICATION_RULE = [
    "1. BLOCKED if no archive is replayable.",
    "2. BLOCKED if any test failed or errored.",
    "3. BLOCKED if, for any replayable archive: the look-ahead audit did not pass, the double replay was not identical, "
    "a referenced raw body is missing or fails its hash, or any database integrity check is non-zero.",
    "4. INSUFFICIENT DATA if the primary archive (the replayable archive with the most assessments) has zero "
    "assessments that reached move classification.",
    "5. VERIFIED WITH LIMITATIONS if, in the primary archive, any required capability is OK in fewer than "
    "REQUIRED_OK_SHARE of assessments.",
    "6. Otherwise REAL-DATA PIPELINE VERIFIED.",
]
REQUIRED_OK_SHARE = 0.5


def classify(ev: dict) -> tuple[str, list[str], dict]:
    """Apply CLASSIFICATION_RULE mechanically. Returns (classification, reasons, every measured input)."""
    inputs: dict = {"required_ok_share": REQUIRED_OK_SHARE, "tests_failed": ev["tests"]["failed"],
                    "tests_errors": ev["tests"]["errors"], "archives": {}}
    rep = [r for r in ev["runs"] if r.get("replayable")]
    for r in ev["runs"]:
        a = {"replayable": bool(r.get("replayable"))}
        if r.get("replayable"):
            pg = r["postgres"] if isinstance(r["postgres"], dict) else {}
            a.update({"lookahead_all_passed": r["lookahead"]["all_passed"],
                      "double_replay_identical": r["determinism"]["identical"],
                      "raw_referenced_but_missing": r["raw_audit"]["referenced_but_missing"],
                      "raw_hash_mismatches": sum(v.get("hash_mismatch", 0) for v in r["raw_audit"]["by_provider"].values()),
                      "db_all_checks_zero": pg.get("all_checks_zero"),
                      "assessments": r["report"]["decisions"]["total_replay_assessments"],
                      "classified_assessments": r["report"]["decisions"]["total_replay_assessments"]
                      - r["report"]["decisions"]["unclassified"],
                      "capability_ok_share": {cap: (r["report"]["missingness"].get(fk, {}).get("OK", 0.0) if fk else 0.0)
                                              for cap, (_, fk) in REQUIRED_CAPABILITIES.items()}})
        inputs["archives"][r["run_id"]] = a
    if not rep:
        return "BLOCKED", ["rule 1: no archive is replayable"], inputs
    if ev["tests"]["failed"] or ev["tests"]["errors"]:
        return "BLOCKED", ["rule 2: test failures"], inputs
    for r in rep:
        a = inputs["archives"][r["run_id"]]
        bad = [k for k, ok in (("lookahead_all_passed", a["lookahead_all_passed"]),
                               ("double_replay_identical", a["double_replay_identical"]),
                               ("raw_referenced_but_missing", a["raw_referenced_but_missing"] == 0),
                               ("raw_hash_mismatches", a["raw_hash_mismatches"] == 0),
                               ("db_all_checks_zero", a["db_all_checks_zero"] is not False)) if not ok]
        if bad:
            return "BLOCKED", [f"rule 3: {r['run_id']} failed {', '.join(bad)}"], inputs
    primary = max(rep, key=lambda r: (inputs["archives"][r["run_id"]]["assessments"], r["run_id"]))
    pa = inputs["archives"][primary["run_id"]]
    inputs["primary_archive"] = primary["run_id"]
    if pa["classified_assessments"] == 0:
        return "INSUFFICIENT DATA", [f"rule 4: {primary['run_id']} has 0 classified assessments"], inputs
    short = [f"rule 5: {cap} OK in {share:.1%} of {primary['run_id']} assessments (< {REQUIRED_OK_SHARE:.0%}; "
             f"needed by {REQUIRED_CAPABILITIES[cap][0]})"
             for cap, share in pa["capability_ok_share"].items() if share < REQUIRED_OK_SHARE]
    if short:
        return "VERIFIED WITH LIMITATIONS", short, inputs
    return "REAL-DATA PIPELINE VERIFIED", ["rule 6: all gates passed and required capabilities covered"], inputs


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
    cls, why = ev["classification"]["result"], ev["classification"]["reasons"]
    rep = [r for r in ev["runs"] if r.get("replayable")]
    pid = ev["classification"]["inputs"].get("primary_archive")
    primary = next((r for r in rep if r["run_id"] == pid), None)
    L = []
    a = L.append
    a("# Phase 2 Real-Data Replay Report\n")
    a("_Generated by `python -m autopsyx phase2-verify` from `artifacts/phase2/PHASE2_EVIDENCE.json`. "
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
    a("### Classification rule (applied in order by `research/phase2_verify.classify`)\n")
    for line in ev["classification"]["rule"]:
        a(f"    {line}")
    ci = ev["classification"]["inputs"]
    a(f"\nREQUIRED_OK_SHARE = {ci['required_ok_share']}; tests failed = {ci['tests_failed']}, errors = {ci['tests_errors']}; "
      f"primary archive = `{ci.get('primary_archive')}`.\n")
    rf = ev["rule_freeze"]
    a(_t([["rule sha256 in force", rf["current_rule_sha256"]], ["rule sha256 frozen", rf["frozen_rule_sha256"]],
          ["frozen at commit (parent of the commit that added the newest archive)", rf["frozen_commit"]],
          ["newest archive / commit", f"{rf['newest_archive']} / {rf['newest_archive_commit']}"],
          ["identical", rf["identical_to_frozen"]], ["missing evidence", rf["missing_evidence_treatment"]],
          ["incomplete acquisition", rf["acquisition_incomplete_treatment"]]], ["rule freeze", "value"]))
    a("")
    a("### Measurements the rule evaluated\n")
    caps = list(REQUIRED_CAPABILITIES)
    a(_t([[aid, x["replayable"], x.get("lookahead_all_passed"), x.get("double_replay_identical"),
           x.get("raw_referenced_but_missing"), x.get("raw_hash_mismatches"), x.get("db_all_checks_zero"),
           x.get("assessments"), x.get("classified_assessments"),
           *((_pct(x["capability_ok_share"][c]) if "capability_ok_share" in x else None) for c in caps)]
          for aid, x in ci["archives"].items()],
         ["archive", "replayable", "look-ahead passed", "double replay identical", "raw missing", "raw hash mismatch",
          "db checks zero", "assessments", "classified", *(f"{c} OK" for c in caps)]))
    a("")
    a("### Per-archive classification (same rule applied to each archive alone)\n")
    a(_t([[r["run_id"], r["archive_classification"]["classification"], "; ".join(r["archive_classification"]["reasons"])]
          for r in ev["runs"]], ["archive", "classification", "reasons"]))
    a("")
    a("## Archive Comparison\n")
    fk = ["discovered", "attempted", "successful", "evaluable", "classified", "unclassified_or_incomplete"]
    a(_t([[k, *(r["funnel"][k] for r in ev["runs"])] for k in fk], ["universe", *(r["run_id"] for r in ev["runs"])]))
    a("")
    ca_keys = ["assessments", "evaluable_assessments", "classified_assessments", "fresh_evaluable_assessments",
               "required_data_unavailable_assessments"]
    a(_t([[k, *(r["coverage_adjusted"][k] if "coverage_adjusted" in r else "not replayable" for r in ev["runs"])]
          for k in ca_keys], ["count", *(r["run_id"] for r in ev["runs"])]))
    a("")
    rate_keys = ["evaluable_share_of_all", "classified_share_of_all", "classified_share_of_evaluable",
                 "fresh_share_of_evaluable", "signals_per_evaluable", "creator_input_unknown_share"]
    rows = []
    for r in ev["runs"]:
        if "coverage_adjusted" not in r:
            continue
        for k in rate_keys:
            x = r["coverage_adjusted"][k]
            rows.append([r["run_id"], k, x["numerator"], x["denominator"], _pct(x["value"]), x["numerator_definition"],
                         x["denominator_definition"]])
    a(_t(rows, ["archive", "rate", "numerator", "denominator", "value", "numerator is", "denominator is"]))
    a("\nDefinitions: " + "; ".join(f"**{k}**: {v}" for k, v in ev["runs"][0]["funnel"]["definitions"].items()) + ".\n")
    for r in ev["runs"]:
        a(f"**{r['run_id']} per token**\n")
        a(_t([[x["token"], x["stratum"], x["successful"], x["evaluable"], x["classified"], x["backfill_ok"],
               x["backfill_failed"], x["distinct_bars"], x["bar_history_minutes"], x["holder_snapshots"],
               x["holder_snapshots_with_creator_pct"], x["replay_steps"],
               sum(x["failed_responses"].values())] for x in r["funnel"]["per_token"]],
             ["token", "stratum", "successful", "evaluable", "classified", "backfill ok", "backfill failed",
              "distinct bars", "bar history (min)", "holder snapshots", "with creator %", "replay steps",
              "failed responses"]))
        a("")
        a(_t([[x["token"], x["reduction_reason"] or "classified"] for x in r["funnel"]["per_token"]],
             ["token", "why it stops before CLASSIFIED"]))
        a("")

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
           "onchain, backtest, journal)", "; ".join(sc["engine_changed_lines"]) or "none"],
          ["engine changes not in the explained list", sc["engine_changes_unexplained"] or "none"],
          ["data-contract files changed", sc["adapted_diff_stat"]],
          ["config lines removed or changed", len(sc["config_lines_removed"])],
          ["config lines added", "; ".join(x.strip() for x in sc["config_lines_added"] if x.strip() and not x.strip().startswith("#"))],
          ["ML / execution terms present in package", sc["forbidden_terms_present"] or "none"]], ["check", "result"]))
    for f, x in sc["engine_changes_explained"].items():
        a(f"\n**Engine change `{f}`**: {x['reason']}\n\n```diff\n" + "\n".join("-" + l for l in x["removed"])
          + "\n" + "\n".join("+" + l for l in x["added"]) + "\n```")
    a("\nChanged data-contract files: " + ", ".join(f"`{f}`" for f in sc["adapted_files"]) + ". Their changes are "
      "listed in DATA_PROVENANCE.md and SYSTEM_STATUS.md (coverage-aware bars and participation, stale-liquidity fix, "
      "capability gating of detectors, provenance fields, transport repairs). No threshold, weight, signal, entry, "
      "exit, risk or ranking rule changed; the single engine edit above changes the order of reason strings only.\n")

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
    cls, why = ev["classification"]["result"], ev["classification"]["reasons"]
    rep = [r for r in ev["runs"] if r.get("replayable")]
    pid = ev["classification"]["inputs"].get("primary_archive")
    primary = next((r for r in rep if r["run_id"] == pid), None)
    t = ev["tests"]
    L = ["# System Status\n",
         "_Generated by `python -m autopsyx phase2-verify` from `artifacts/phase2/PHASE2_EVIDENCE.json`._\n",
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
    L.append("* See docs/PHASE2_REPORT.md, Known Limitations, for the full list.\n")
    L.append("## What this status does not claim\n")
    L.append("No live-trading validation, no profitability, no predictive validity. Replay executing on real data is an "
             "ingestion and integrity result only. No execution code exists.\n")
    L.append(f"## Final Phase 2 classification\n\n**{cls}**\n")
    return "\n".join(L) + "\n"
