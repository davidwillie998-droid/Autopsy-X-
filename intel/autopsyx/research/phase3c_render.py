"""Phase 3C renderers. Every function here formats values already present in
the evidence dict (`phase3c_pipeline.run()`'s return value); none computes a
number that is not already there, matching the renderer-never-computes rule
the Phase 2/3A/3B renderers already follow.
"""
from __future__ import annotations

import json
from pathlib import Path


def _fmt(x) -> str:
    if x is None:
        return "n/a"
    if isinstance(x, bool):
        return str(x)
    if isinstance(x, float):
        return f"{x:.4g}"
    return str(x)


def _t(rows: list[list], head: list[str]) -> str:
    out = ["| " + " | ".join(head) + " |", "|" + "|".join("---" for _ in head) + "|"]
    for r in rows:
        out.append("| " + " | ".join(_fmt(c) for c in r) + " |")
    return "\n".join(out)


def render_data_audit(out: dict) -> str:
    L = ["# Phase 3C Data Audit", "",
        f"Contract hash `{out['contract_hash']}`. Included archives: {', '.join(out['included_archives'])}.", "",
        "## Contamination (token overlap across archives)", "",
        f"Contamination-free: **{out['contamination']['contamination_free']}**.", "",
        _t([[a, n] for a, n in sorted(out['contamination']['per_archive_token_count'].items())],
           ["Archive", "Tokens"]), ""]
    if out["contamination"]["overlaps"]:
        L += ["", "Overlaps found (contamination):", ""]
        for ov in out["contamination"]["overlaps"]:
            L.append(f"* {ov['archives']}: {ov['shared_tokens']}")
    L += ["", "## Per-archive observation coverage", ""]
    for arch, a in out["data_audit"]["archives"].items():
        L += [f"### {arch}", "",
             f"* Observations: {a['observation_count']}, tokens with any observation: {a['tokens_with_any_observation']}",
             f"* Provenance: source={a['provenance']['source']}, verified={a['provenance']['verified']}, "
             f"scope={a['provenance']['scope']}",
             f"* Duplicates/staleness: {json.dumps(a['duplicates_and_staleness'])}", ""]
        L += [_t([[k, v] for k, v in sorted(a["observation_states"].items())], ["kind|state", "count"]), ""]
    L += ["## New archives excluded (if any)", ""]
    if out["new_archives_excluded"]:
        for x in out["new_archives_excluded"]:
            L.append(f"* **{x['archive']}**: {x['reason']}")
    else:
        L.append("None: every acquired Phase 3C archive passed provenance and completion.")
    L.append("")
    return "\n".join(L)


def render_provenance_report(out: dict) -> str:
    L = ["# Phase 3C Provenance Report", "",
        f"Repository commit `{out['repository_commit']}`. Configuration hash `{out['configuration_hash']}`. "
        f"Phase 3A baseline `{out['phase3a_commit']}`, Phase 3B baseline `{out['phase3b_commit']}`.", "",
        "## Included archives", "", _t([[a] for a in out["included_archives"]], ["Archive"]), "",
        "## Excluded (provenance or completion failed)", ""]
    if out["new_archives_excluded"]:
        for x in out["new_archives_excluded"]:
            d = x["detail"]
            L.append(f"* **{x['archive']}**: verified={d.get('verified')}, acquisition_status={d.get('acquisition_status')}, "
                     f"reproducible={d.get('reproducible')}, committed_matches_runner={d.get('committed_matches_runner')}")
    else:
        L.append("None.")
    L += ["", "Every included archive's hash chain (runner hash = independent rebuild 1 = independent rebuild 2 "
         "= committed canonical hash) was verified by `data.provenance.verify()`, the same function and the same "
         "procedure Phase 3A's archive D2 used -- see `docs/PHASE3A_REPORT.md` for that mechanism's own "
         "verification, and `research/phase3c/evidence.json` -> `data_audit.archives.*.provenance` for each "
         "archive's result here.", ""]
    return "\n".join(L)


def render_statistical_report(out: dict) -> str:
    L = ["# Phase 3C Statistical Report", "",
        f"Contract hash `{out['contract_hash']}` (version `{out['contract_version']}`, unchanged from Phase 3B). "
        f"Statistical protocol: `docs/PHASE3C_STATISTICAL_PROTOCOL.md`. MIN_SAMPLE={out['min_sample']} "
        f"(frozen, imported from Phase 3B). Archives: {', '.join(out['included_archives'])}.", "",
        "## Hypothesis family", "",
        _t([[h["hypothesis_id"], h["feature"], h["n_rows_joined"], h.get("n_distinct_tokens", "n/a"),
             h["min_sample_required"], h["classification"]] for h in out["hypotheses"]],
           ["ID", "Feature", "Rows", "Distinct tokens", "Min sample", "Classification"]), "",
        "## Per-hypothesis detail", ""]
    for h in out["hypotheses"]:
        L += [f"### {h['hypothesis_id']}", "", f"*Reason*: {h['reason']}", ""]
        for target, t in h.get("targets", {}).items():
            L.append(f"* **{target}**: n={t['n']}, spearman_r={_fmt(t['spearman_r'])}, "
                     f"raw_p={_fmt(t['permutation_p'])}, FDR_p={_fmt(t.get('permutation_p_fdr'))}")
            pa = h.get("per_archive", {}).get(target, {})
            if pa:
                L.append("  * Per archive: " + "; ".join(f"{a}: n_tokens={v['n_tokens']}, spearman={_fmt(v['spearman'])}"
                                                         for a, v in sorted(pa.items())))
            oos = h.get("oos", {}).get(target)
            if oos:
                L.append(f"  * OOS: in-sample n_tokens={oos['in_sample']['n_tokens']} sign={oos['in_sample']['sign']}, "
                        f"OOS n_tokens={oos['oos']['n_tokens']} sign={oos['oos']['sign']}, agree={oos['signs_agree']}")
        L.append("")
    L += ["## Overall classification", "", f"**{out['overall_classification']['result']}**", "",
         f"By classification: {json.dumps(out['overall_classification']['by_classification'])}.", ""]
    return "\n".join(L)


def render_replication_report(out: dict) -> str:
    h10 = next(h for h in out["hypotheses"] if h["hypothesis_id"] == "H10")
    aud = h10.get("replication_audit", {})
    L = ["# Phase 3C Replication Report", "",
        "Dedicated H10 replication audit (Phase 3C instruction 9): the Phase 3B false positive "
        "(spearman~=0.65 on 109 rows / 21 tokens) is re-examined collapsing each token to one representative row, "
        "controlling for archive identity, and broken down by archive.", "",
        f"H10 classification in this evidence: **{h10['classification']}**. {h10['reason']}", "",
        f"Tokens after one-row-per-token collapse: {aud.get('n_tokens_collapsed', 'n/a')}.", ""]
    for target, t in aud.get("per_target", {}).items():
        L += [f"## {target}", "",
             f"* Spearman, one row per token: {_fmt(t.get('spearman_one_row_per_token'))}",
             f"* Partial Spearman controlling for archive identity: "
             f"{_fmt(t.get('partial_spearman_controlling_archive_identity'))}", ""]
        pa = t.get("per_archive", {})
        if pa:
            L += [_t([[a, v["n_rows"], v["n_tokens"], _fmt(v["spearman"]), _fmt(v["permutation_p"])]
                     for a, v in sorted(pa.items())], ["Archive", "Rows", "Tokens", "Spearman", "Permutation p"]), ""]
    L += ["## Conclusion", "",
         "The relationship does not survive as independent evidence under the pre-registered minimum-sample rule "
         "applied to distinct tokens; whether it would survive at a larger n is the open question Phase 3C's "
         "expanded archive set tests directly, reported in the hypothesis-family table above.", ""]
    return "\n".join(L)


def render_system_status(out: dict) -> str:
    L = ["# Phase 3C System Status", "",
        "Living status of the Phase 3C evidence-expansion and replication exercise, generated from "
        "`research/phase3c/evidence.json`. Phase 3A is frozen and finalized "
        f"(`{out['phase3a_commit']}`, VERIFIED WITH LIMITATIONS); Phase 3B is frozen "
        f"(`{out['phase3b_commit']}`, INSUFFICIENT EVIDENCE).", "",
        f"## Phase 3C classification: {out['overall_classification']['result']}", "",
        f"* Archives included: {', '.join(out['included_archives'])}",
        f"* Contamination-free: {out['contamination']['contamination_free']}",
        f"* MIN_SAMPLE (frozen): {out['min_sample']}",
        f"* Hypotheses tested: {out['overall_classification']['hypotheses_tested']}",
        f"* By classification: {json.dumps(out['overall_classification']['by_classification'])}", "",
        "## What runs", "",
        "* Acquisition (read-only, keyless), identical procedure to Phase 3A, new independent archives only.",
        "* The frozen Phase 3B statistical contract and toolkit, unmodified.",
        "* Token-level sample-size gate, block permutation, BH-FDR, winsorizing, temporal-stability split,",
        "  archive-identity and step-index adversarial checks, walk-forward OOS (where MIN_SAMPLE is reached).",
        "* No order placement, no wallets, no strategy logic, no production EA (none exists in this repository).",
        "", "## Phase 3D", "", "NOT STARTED.", ""]
    return "\n".join(L)


def write_all(out: dict, root: Path) -> None:
    (root / "docs").mkdir(parents=True, exist_ok=True)
    (root / "docs" / "PHASE3C_DATA_AUDIT.md").write_text(render_data_audit(out))
    (root / "docs" / "PHASE3C_PROVENANCE_REPORT.md").write_text(render_provenance_report(out))
    (root / "docs" / "PHASE3C_STATISTICAL_REPORT.md").write_text(render_statistical_report(out))
    (root / "docs" / "PHASE3C_REPLICATION_REPORT.md").write_text(render_replication_report(out))
    (root / "docs" / "PHASE3C_SYSTEM_STATUS.md").write_text(render_system_status(out))
    results_dir = root / "research" / "phase3c"
    results_dir.mkdir(parents=True, exist_ok=True)
    (results_dir / "evidence.json").write_text(json.dumps(out, indent=1, sort_keys=True, default=str) + "\n")
    from . import phase3c_pipeline as p3c
    p3c.write_ledger(out, results_dir / "phase3c_research_ledger.csv")
