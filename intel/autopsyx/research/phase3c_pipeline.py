"""Phase 3C pipeline: evidence expansion and replication, over Phase 3A's
eligible archives plus any newly acquired, independently provenance-verified
archive. Imports the Phase 3B contract and statistics toolkit unmodified;
adds only what Phase 3B did not need: an archive-identity-aware replication
audit, a per-archive/per-cohort breakdown, a walk-forward OOS gate, and the
three-way REPLICATED EVIDENCE / FAILED REPLICATION / INSUFFICIENT EVIDENCE
classification the Phase 3C statistical protocol defines.
"""
from __future__ import annotations

import hashlib
import json
import math
from collections import defaultdict
from pathlib import Path

from ..core.config import Config
from . import phase3b_contract as contract
from . import phase3b_data as d3b
from . import phase3b_pipeline as p3b
from . import phase3b_stats as stats
from . import phase3c_data as d3c
from .phase2_verify import git

ROOT = d3c.ROOT
HYPOTHESIS_IDS = contract.ELIGIBLE_IDS  # same tuple object Phase 3B uses; not redefined
MIN_SAMPLE = contract.MIN_SAMPLE  # same int Phase 3B uses; not redefined or relaxed


# ------------------------------------------------------------ replication ----
def per_archive_breakdown(rows: list[dict], target: str) -> dict:
    by_archive: dict[str, dict] = defaultdict(lambda: defaultdict(list))
    for r in rows:
        by_archive[r["archive"]][r["token"]].append(r)
    out = {}
    for arch, by_token in by_archive.items():
        blocks = {k: [(x["x"], x[target]) for x in v] for k, v in by_token.items()}
        xs = [p[0] for v in blocks.values() for p in v]
        ys = [p[1] for v in blocks.values() for p in v]
        perm = stats.block_permutation_test(blocks, stat_fn=stats.spearman, n_permutations=contract.N_PERMUTATIONS) \
            if len(by_token) >= 2 else None
        out[arch] = {"n_rows": len(xs), "n_tokens": len(by_token), "spearman": stats.spearman(xs, ys),
                    "permutation_p": perm.p_value if perm else None}
    return out


def h10_replication_audit(rows_h10: list[dict], archives_order: list[str]) -> dict:
    """Phase 3C instruction 9: collapse each token to one representative row
    (its earliest forward-joinable step -- not cherry-picked, deterministic),
    control for archive identity, and break down by archive."""
    by_token: dict[str, list] = defaultdict(list)
    for r in rows_h10:
        by_token[r["token"]].append(r)
    # Select by observation time first: archive names are identifiers, not chronology.
    # Sorting archive names first can silently choose a later observation and bias replication.
    collapsed = [
        min(rs, key=lambda r: (
            r.get("as_of") if isinstance(r.get("as_of"), (int, float)) else float("inf"),
            r.get("step_index", float("inf")),
            r.get("archive", ""),
        ))
        for rs in by_token.values()
    ]
    arch_code = {a: i for i, a in enumerate(sorted(archives_order))}
    out = {"n_tokens_collapsed": len(collapsed), "per_target": {}}
    for target in ("y_classified", "y_direction"):
        xs = [r["x"] for r in collapsed]
        ys = [r[target] for r in collapsed]
        zs = [arch_code[r["archive"]] for r in collapsed]
        spear = stats.spearman(xs, ys)
        out["per_target"][target] = {
            "spearman_one_row_per_token": spear,
            "partial_spearman_controlling_archive_identity": stats.partial_spearman(xs, ys, zs) if spear is not None else None,
            "per_archive": per_archive_breakdown(rows_h10, target),
        }
    return out


def walk_forward_oos(by_token: dict, target: str) -> dict | None:
    """Chronological holdout with a per-token label-horizon embargo.

    The cutoff is chosen from observation timestamps, not token identity. Rows
    from the future period are never moved into the in-sample set. For each
    token, in-sample rows whose forward label could reach the first OOS step
    are purged using the frozen Phase 3B horizon. This is a validation sign
    check, not proof of profitability or independent IID observations.
    """
    rows = [r for token_rows in by_token.values() for r in token_rows
            if isinstance(r.get("as_of"), (int, float)) and target in r
            and isinstance(r.get("step_index"), int)]
    timestamps = sorted({r["as_of"] for r in rows})
    if len(timestamps) < 4:
        return None
    cutoff = timestamps[len(timestamps) // 2]
    oos_rows = [r for r in rows if r["as_of"] >= cutoff]
    if not oos_rows:
        return None

    first_oos_step = {}
    for token, token_rows in by_token.items():
        future_steps = [r["step_index"] for r in token_rows
                        if r.get("as_of", float("-inf")) >= cutoff
                        and isinstance(r.get("step_index"), int)]
        if future_steps:
            first_oos_step[token] = min(future_steps)

    horizon = contract.HORIZON_STEPS
    in_rows = [
        r for token, token_rows in by_token.items()
        for r in token_rows
        if r.get("as_of", float("inf")) < cutoff
        and token in first_oos_step
        and isinstance(r.get("step_index"), int)
        and r["step_index"] + horizon < first_oos_step[token]
        and target in r
    ]
    in_tokens = {r.get("token") for r in in_rows if r.get("token")}
    oos_tokens = {r.get("token") for r in oos_rows if r.get("token")}
    if len(in_rows) < 3 or len(oos_rows) < 3 or len(in_tokens) < 3 or len(oos_tokens) < 3:
        return None

    signs = {}
    for name, sample in (("in_sample", in_rows), ("oos", oos_rows)):
        xs = [r["x"] for r in sample]
        ys = [r[target] for r in sample]
        s = stats.spearman(xs, ys)
        signs[name] = {
            "n_rows": len(sample),
            "n_tokens": len({r.get("token") for r in sample if r.get("token")}),
            "spearman": s,
            "sign": 0 if s is None or s == 0 else math.copysign(1, s),
        }
    if signs["in_sample"]["spearman"] is None or signs["oos"]["spearman"] is None:
        return None
    return {
        **signs,
        "method": "chronological_timestamp_split_with_label_horizon_embargo",
        "cutoff_as_of": cutoff,
        "horizon_steps_embargo": horizon,
        "in_sample_purged_rows": sum(
            1 for token, token_rows in by_token.items()
            for r in token_rows
            if r.get("as_of", float("inf")) < cutoff
            and token in first_oos_step
            and isinstance(r.get("step_index"), int)
            and r["step_index"] + horizon >= first_oos_step[token]
        ),
        "signs_agree": signs["in_sample"]["sign"] == signs["oos"]["sign"] != 0,
    }


def chronological_training_rows(rows: list[dict]) -> tuple[list[dict], dict]:
    """Return only pre-cutoff rows after purging labels that overlap the future holdout."""
    valid = [r for r in rows if isinstance(r.get("as_of"), (int, float))
             and isinstance(r.get("step_index"), int)]
    timestamps = sorted({r["as_of"] for r in valid})
    if len(timestamps) < 4:
        return [], {"available": False, "reason": "fewer_than_four_distinct_timestamps"}
    cutoff = timestamps[len(timestamps) // 2]
    first_oos_step = {}
    for r in valid:
        if r["as_of"] >= cutoff:
            token = r.get("token")
            if token:
                first_oos_step[token] = min(first_oos_step.get(token, r["step_index"]), r["step_index"])
    horizon = contract.HORIZON_STEPS
    train = [r for r in valid if r["as_of"] < cutoff
             and r.get("token") in first_oos_step
             and r["step_index"] + horizon < first_oos_step[r["token"]]]
    purged = sum(1 for r in valid if r["as_of"] < cutoff
                 and r.get("token") in first_oos_step
                 and r["step_index"] + horizon >= first_oos_step[r["token"]])
    report = {
        "available": True, "method": "chronological_timestamp_split_with_label_horizon_embargo",
        "cutoff_as_of": cutoff, "horizon_steps_embargo": horizon,
        "n_train_rows_after_purge": len(train),
        "n_train_tokens_after_purge": len({r["token"] for r in train if r.get("token")}),
        "n_oos_rows": sum(1 for r in valid if r["as_of"] >= cutoff),
        "n_oos_tokens": len({r["token"] for r in valid if r["as_of"] >= cutoff and r.get("token")}),
        "n_train_rows_purged": purged,
    }
    return train, report


def assert_temporal_isolation(rows: list[dict], train_rows: list[dict], split_report: dict) -> None:
    """Fail closed if discovery and validation timestamps overlap or labels cross the embargo."""
    if not split_report.get("available"):
        return
    cutoff = split_report.get("cutoff_as_of")
    if not isinstance(cutoff, (int, float)):
        raise ValueError("Phase 3C temporal isolation failed: missing numeric holdout cutoff")

    validation_rows = [
        r for r in rows
        if isinstance(r.get("as_of"), (int, float))
        and isinstance(r.get("step_index"), int)
        and r["as_of"] >= cutoff
        and r.get("token")
    ]
    if not train_rows or not validation_rows:
        raise ValueError("Phase 3C temporal isolation failed: empty discovery or validation partition")

    max_discovery_timestamp = max(r["as_of"] for r in train_rows)
    min_validation_timestamp = min(r["as_of"] for r in validation_rows)
    if not max_discovery_timestamp < min_validation_timestamp:
        raise ValueError(
            "Phase 3C temporal leakage: max(discovery_timestamp) must be strictly less "
            "than min(validation_timestamp)"
        )

    first_oos_step = {}
    for r in validation_rows:
        token = r["token"]
        first_oos_step[token] = min(first_oos_step.get(token, r["step_index"]), r["step_index"])
    horizon = contract.HORIZON_STEPS
    for r in train_rows:
        first_step = first_oos_step.get(r.get("token"))
        if first_step is None or r["step_index"] + horizon >= first_step:
            raise ValueError(
                "Phase 3C label leakage: discovery row overlaps the per-token validation horizon"
            )


# --------------------------------------------------------------- classify ----
def classify_hypothesis_3c(hid: str, n_tokens: int, n_rows: int, targets: dict, per_archive: dict,
                           oos: dict) -> tuple[str, str]:
    if n_tokens < MIN_SAMPLE:
        return ("INSUFFICIENT EVIDENCE",
               f"n_tokens={n_tokens} (n_rows={n_rows}) < MIN_SAMPLE={MIN_SAMPLE}; the frozen Phase 3B threshold "
               "is not relaxed for Phase 3C")
    tested = {t: v for t, v in targets.items() if v.get("spearman_r") is not None}
    if not tested:
        return "FAILED REPLICATION", "every target is statistically undefined (zero variance) even though n_tokens >= MIN_SAMPLE"
    significant = {t: v for t, v in tested.items() if v.get("permutation_p_fdr") is not None and v["permutation_p_fdr"] < contract.ALPHA}
    if not significant:
        return "FAILED REPLICATION", "n_tokens >= MIN_SAMPLE reached, but no target's FDR-corrected p-value clears alpha"
    for t, v in significant.items():
        adv = v.get("adversarial", {})
        step_confound = (adv.get("partial_spearman_controlling_step_index") is not None
                        and abs(adv["partial_spearman_controlling_step_index"]) < abs(v["spearman_r"]) * 0.5)
        pa = per_archive.get(t, {})
        signs = [math.copysign(1, x["spearman"]) for x in pa.values() if x.get("spearman") is not None and x.get("n_tokens", 0) >= 3]
        archive_agree = len(signs) >= 2 and len(set(signs)) == 1
        robust = v.get("robustness", {}).get("spearman_winsorized") is not None and v["spearman_r"] * v["robustness"]["spearman_winsorized"] > 0
        ts = v.get("temporal_stability", {})
        temporal_agree = (ts.get("early", {}).get("spearman") or 0) * (ts.get("late", {}).get("spearman") or 0) > 0
        oos_t = oos.get(t)
        oos_ok = bool(oos_t and oos_t.get("signs_agree"))
        if step_confound:
            return "FAILED REPLICATION", (f"{t}: raw spearman={v['spearman_r']:.3f} collapses under the step-index "
                                          "adversarial control; overlapping-observations/elapsed-time confound, "
                                          "not an incremental-information finding")
        if not archive_agree:
            return "FAILED REPLICATION", f"{t}: sign does not agree across the archives with their own n>=3 ({pa})"
        if not robust:
            return "FAILED REPLICATION", f"{t}: does not survive winsorizing"
        if not temporal_agree:
            return "FAILED REPLICATION", f"{t}: sign is not stable across the two chronological halves"
        if not oos_ok:
            return "FAILED REPLICATION", f"{t}: walk-forward OOS sign does not agree with the in-sample sign (or could not be computed)"
        return "REPLICATED EVIDENCE", f"{t}: survives FDR, both adversarial checks, archive agreement, robustness, temporal stability and OOS"
    return "FAILED REPLICATION", "no significant target survived the full replication battery"


def overall_classification_3c(results: list[dict]) -> dict:
    from collections import Counter
    by_class = Counter(r["classification"] for r in results)
    if by_class.get("REPLICATED EVIDENCE", 0) > 0:
        overall = "REPLICATED EVIDENCE"
    elif by_class.get("FAILED REPLICATION", 0) > 0:
        overall = "FAILED REPLICATION"
    else:
        overall = "INSUFFICIENT EVIDENCE"
    return {"by_classification": dict(sorted(by_class.items())), "hypotheses_tested": len(results), "result": overall}


# --------------------------------------------------------------------- run ----
def run(work: Path) -> dict:
    cfg = Config.load()
    code_version = git("rev-parse", "HEAD")
    included, excluded_new = d3c.eligible_archives()
    contamination = d3c.token_overlap_across_archives(included)
    audit = p3b.data_audit(included)
    all_journal = {d.name: d3b.journal_rows(d, cfg, work, code_version) for d in included}
    rows_by_h = p3b.build_rows(included, cfg, work, code_version, all_journal=all_journal)
    dedup_report = {}
    if not contamination["contamination_free"]:
        for hid in list(rows_by_h):
            rows_by_h[hid], rep = d3c.deduplicate_rows_across_archives(rows_by_h[hid], included)
            if rep["dropped"]:
                dedup_report[hid] = rep

    results = []
    raw_pvals, raw_idx = [], []
    train_rows_by_h = {}
    split_reports = {}
    for hid in HYPOTHESIS_IDS:
        spec = contract.HYPOTHESIS_SPECS[hid]
        engine_ok = p3b._engine_ok_share(included, all_journal, spec["engine_fields"])
        full_rows = rows_by_h.get(hid, [])
        train_rows, split_report = chronological_training_rows(full_rows)
        # Enforce temporal separation at runtime, not only in regression tests.
        # Any overlap or label-horizon breach fails closed before discovery statistics run.
        assert_temporal_isolation(full_rows, train_rows, split_report)
        train_rows_by_h[hid] = train_rows
        split_reports[hid] = split_report
        # Discovery statistics, FDR correction, archive breakdowns and robustness
        # are computed on purged pre-cutoff data only. The future holdout is used
        # only by the separate OOS validation below.
        base = p3b.evaluate_hypothesis(hid, train_rows, engine_ok)
        base.pop("classification", None)
        base.pop("reason", None)
        base["chronological_split"] = split_report
        results.append(base)
        for target, t in base.get("targets", {}).items():
            if t.get("permutation_p") is not None:
                raw_pvals.append(t["permutation_p"])
                raw_idx.append((hid, target))
    corrected = stats.bh_fdr(raw_pvals)
    corrected_map = dict(zip(raw_idx, corrected))
    for r in results:
        for target, t in r.get("targets", {}).items():
            t["permutation_p_fdr"] = corrected_map.get((r["hypothesis_id"], target))

    archive_names = [d.name for d in included]
    for r in results:
        hid = r["hypothesis_id"]
        # Full rows are retained only for the independent chronological holdout.
        full_rows = rows_by_h.get(hid, [])
        rows = train_rows_by_h.get(hid, [])
        by_token: dict[str, list] = defaultdict(list)
        for row in full_rows:
            by_token[row["token"]].append(row)
        per_archive = {t: per_archive_breakdown(rows, t) for t in r.get("targets", {})}
        oos = {}
        if r.get("n_distinct_tokens", 0) >= MIN_SAMPLE:
            for t in r.get("targets", {}):
                o = walk_forward_oos(by_token, t)
                if o is not None:
                    oos[t] = o
        r["per_archive"] = per_archive
        r["oos"] = oos
        r["classification"], r["reason"] = classify_hypothesis_3c(
            hid, r.get("n_distinct_tokens", 0), r.get("n_rows_joined", 0), r.get("targets", {}), per_archive, oos)
        if hid == "H10":
            r["replication_audit"] = h10_replication_audit(rows, archive_names)

    overall = overall_classification_3c(results)
    return {
        "schema": "phase3c.evidence.1", "repository_commit": code_version, "configuration_hash": cfg.fingerprint(),
        "phase3a_commit": "617355f874d949431eb93d8ac2d3ecc7b6479aa3", "phase3b_commit": "f21f3bc2e18ab64d2b92e203c4202144eabf7eac",
        "contract_hash": contract.contract_hash(), "contract_version": contract.CONTRACT_VERSION,
        "included_archives": archive_names, "new_archives_excluded": excluded_new, "contamination": contamination,
        "deduplication": dedup_report, "data_audit": audit, "hypotheses": results, "overall_classification": overall,
        "min_sample": MIN_SAMPLE, "horizon_steps": contract.HORIZON_STEPS,
    }


# ------------------------------------------------------------------ output ----
LEDGER_FIELDS = ["hypothesis_id", "target", "archive_scope", "n_rows_joined", "n_distinct_tokens", "min_sample_required",
                 "spearman_r", "raw_p", "corrected_p_fdr", "partial_spearman_step_index", "robustness_winsorized",
                 "temporal_early_spearman", "temporal_late_spearman", "oos_signs_agree", "final_classification", "reason"]


def ledger_rows(out: dict) -> list[dict]:
    rows = []
    scope = ", ".join(sorted(out["included_archives"]))
    for h in out["hypotheses"]:
        if not h.get("targets"):
            rows.append({f: "" for f in LEDGER_FIELDS} | {"hypothesis_id": h["hypothesis_id"], "target": "(none)",
                        "archive_scope": scope, "n_rows_joined": h["n_rows_joined"],
                        "n_distinct_tokens": h.get("n_distinct_tokens", ""), "min_sample_required": h["min_sample_required"],
                        "final_classification": h["classification"], "reason": h["reason"]})
            continue
        for target, t in h["targets"].items():
            adv = t.get("adversarial", {})
            ts = t.get("temporal_stability", {})
            oos = h.get("oos", {}).get(target, {})
            rows.append({
                "hypothesis_id": h["hypothesis_id"], "target": target, "archive_scope": scope,
                "n_rows_joined": h["n_rows_joined"], "n_distinct_tokens": h["n_distinct_tokens"],
                "min_sample_required": h["min_sample_required"], "spearman_r": t["spearman_r"],
                "raw_p": t["permutation_p"], "corrected_p_fdr": t.get("permutation_p_fdr"),
                "partial_spearman_step_index": adv.get("partial_spearman_controlling_step_index"),
                "robustness_winsorized": t.get("robustness", {}).get("spearman_winsorized"),
                "temporal_early_spearman": ts.get("early", {}).get("spearman"),
                "temporal_late_spearman": ts.get("late", {}).get("spearman"),
                "oos_signs_agree": oos.get("signs_agree"),
                "final_classification": h["classification"], "reason": h["reason"]})
    return rows


def write_ledger(out: dict, path: Path) -> None:
    import csv
    path.parent.mkdir(parents=True, exist_ok=True)
    with open(path, "w", newline="") as fh:
        w = csv.DictWriter(fh, fieldnames=LEDGER_FIELDS)
        w.writeheader()
        for r in ledger_rows(out):
            w.writerow({k: r.get(k, "") for k in LEDGER_FIELDS})
