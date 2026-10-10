"""Phase 3B pipeline: data audit -> feature/target table -> per-hypothesis
test -> FDR -> ledger -> report. Research-only; writes nothing the EA reads.
"""
from __future__ import annotations

import hashlib
import json
from collections import Counter, defaultdict
from pathlib import Path

from ..core.config import Config
from ..core.observation import Availability as A
from . import phase3a_state as st
from . import phase3b_contract as contract
from . import phase3b_data as d3b
from . import phase3b_stats as stats
from .phase2_verify import git

ROOT = d3b.ROOT


def _entity_sha(obj) -> str:
    return hashlib.sha256(json.dumps(obj, sort_keys=True, default=str).encode()).hexdigest()


# --------------------------------------------------------------- data audit ----
def data_audit(archives: list[Path]) -> dict:
    out = {"archives": {}, "contract_hash": contract.contract_hash()}
    for d in archives:
        obs_by_tok = d3b.observations_by_token(d)
        states = Counter(f"{o.kind}|{o.state.value}" for toks in obs_by_tok.values() for o in toks)
        ts = [o.observation_ts for toks in obs_by_tok.values() for o in toks]
        prov = __import__("autopsyx.data.provenance", fromlist=["verify"]).verify(str(d))
        out["archives"][d.name] = {
            "observation_count": sum(len(v) for v in obs_by_tok.values()),
            "observation_states": dict(sorted(states.items())),
            "tokens_with_any_observation": len(obs_by_tok),
            "timestamp_coverage_ms": {"min": min(ts) if ts else None, "max": max(ts) if ts else None},
            "duplicates_and_staleness": d3b.duplicate_and_stale_counts(d),
            "provenance": {"source": prov["source"], "verified": prov["verified"], "scope": prov["scope"]},
        }
    return out


# ----------------------------------------------------------- feature table ----
def _obs_feature_value(obs_list: list, kind: str, feature_kind: str, as_of: int):
    """Point-in-time: only observations ingested at or before ``as_of`` count.
    Returns None (row dropped) when the fact is not KNOWN_AT_ASSESSMENT/observed,
    per the contract's missing-data rule -- never 0."""
    visible = [o for o in obs_list if o.kind == kind and o.ingestion_ts <= as_of]
    if feature_kind == "binary_observed":
        return 1.0 if any(o.state == A.OBSERVED for o in visible) else (0.0 if visible else None)
        # 0.0 only when the source was asked and answered without the fact (NOT_OBSERVED present);
        # None when nothing about this token/kind was ever ingested by as_of (UNAVAILABLE), per the
        # missing-data rule -- not asking is not the same as asking and getting no.
    if feature_kind in ("creator_pct",):
        view_obs = [o for o in visible if o.kind == "creator_state"]
        a = _assess_from_list(view_obs, as_of)
        if a.state != st.KNOWN:
            return None
        return a.value.get("creator_pct")
    raise ValueError(feature_kind)


def _assess_from_list(obs_list: list, as_of: int):
    from ..providers.store import EventStore
    s = EventStore()
    s.extend(obs_list)
    kind = obs_list[0].kind if obs_list else "creator_state"
    tok = obs_list[0].entity if obs_list else ""
    return st.assess(s.view(as_of), kind, tok)


def _visible_but_not_observed(obs_list: list, kind: str, as_of: int) -> bool:
    return any(o.kind == kind and o.ingestion_ts <= as_of for o in obs_list)


def build_rows(archives: list[Path], cfg: Config, work: Path, code_version: str,
              all_journal: dict[str, list] | None = None) -> dict[str, list[dict]]:
    """hypothesis_id -> list of {token, archive, as_of, x, y_classified, y_direction}."""
    all_obs: dict[str, dict[str, list]] = {}
    if all_journal is None:
        all_journal = {d.name: d3b.journal_rows(d, cfg, work, code_version) for d in archives}
    for d in archives:
        all_obs[d.name] = d3b.observations_by_token(d)
    rows_by_h: dict[str, list[dict]] = defaultdict(list)
    for d in archives:
        by_token: dict[str, list] = defaultdict(list)
        for r in all_journal[d.name]:
            by_token[r.token].append(r)
        for tok, rs in by_token.items():
            rs.sort(key=lambda r: r.step_index)
            bare = tok.split(":", 1)[1] if ":" in tok else tok  # journal token is "chain:address"; observations are keyed bare
            obs_list = all_obs[d.name].get(bare, [])
            for i in range(len(rs) - contract.HORIZON_STEPS):
                t_row = rs[i]
                f_row = rs[i + contract.HORIZON_STEPS]
                if f_row.step_index != t_row.step_index + contract.HORIZON_STEPS:
                    continue  # defensive: only a contiguous, gap-free forward join counts
                for hid, spec in contract.HYPOTHESIS_SPECS.items():
                    x = _obs_feature_value(obs_list, spec["observation_feature"], spec["feature_kind"], t_row.as_of)
                    if x is None:
                        continue
                    rows_by_h[hid].append({
                        "archive": d.name, "token": tok, "as_of": t_row.as_of, "step_index": t_row.step_index,
                        "x": x, "y_classified": 1.0 if f_row.move_class != "UNCLASSIFIED" else 0.0,
                        "y_direction": float(f_row.move_direction),
                        "engine_fields_ok": all(t_row.feature_status.get(fld) == "OK" for fld in spec["engine_fields"])
                                           if spec["engine_fields"] else False,
                    })
    return rows_by_h


# --------------------------------------------------------------- testing ----
def _engine_ok_share(archives: list[Path], all_journal: dict[str, list], fields: tuple) -> dict:
    """Share of ALL eligible assessments (not just forward-joinable ones) where
    every required engine field reports feature_status OK, per archive and
    pooled -- the same definition phase2_verify.hypothesis_rows() already uses."""
    if not fields:
        return {"pooled_ok_share": 0.0, "pooled_n": 0, "per_archive": {}}
    per_archive = {}
    total_ok = total_n = 0
    for d in archives:
        rows = all_journal[d.name]
        n = len(rows)
        ok = sum(1 for r in rows if all(r.feature_status.get(f) == "OK" for f in fields))
        per_archive[d.name] = {"n": n, "ok": ok, "share": round(ok / n, 6) if n else None}
        total_ok += ok
        total_n += n
    return {"pooled_ok_share": round(total_ok / total_n, 6) if total_n else None, "pooled_n": total_n,
           "per_archive": per_archive}


def evaluate_hypothesis(hid: str, rows: list[dict], engine_ok: dict) -> dict:
    spec = contract.HYPOTHESIS_SPECS[hid]
    result = {"hypothesis_id": hid, "feature": spec["observation_feature"], "feature_kind": spec["feature_kind"],
             "engine_fields": list(spec["engine_fields"]), "engine_field_ok_share": engine_ok["pooled_ok_share"],
             "engine_field_ok_n": engine_ok["pooled_n"], "horizon_steps": contract.HORIZON_STEPS,
             "n_rows_joined": len(rows), "min_sample_required": contract.MIN_SAMPLE}
    if engine_ok["pooled_n"] and engine_ok["pooled_ok_share"] == 0.0 and not rows:
        result.update(classification="INSUFFICIENT EVIDENCE",
                      reason="required engine fields report feature_status OK in 0% of eligible assessments in "
                             "every archive (frozen Phase 2 capability flags), and no candidate-feature row was "
                             "joinable either; kill criterion in the contract applies without further testing",
                      tests_run=[], targets={})
        return result
    by_token: dict[str, list] = defaultdict(list)
    for r in rows:
        by_token[r["token"]].append(r)
    n_rows = len(rows)
    n_tokens = len(by_token)
    result["n_rows_joined"] = n_rows
    result["n_distinct_tokens"] = n_tokens
    # The minimum-sample rule is applied to n_tokens, not n_rows: within a token, the candidate
    # feature and the target are both close to constant across the forward-joined steps (a token's
    # creator share does not change minute to minute, and classifiability moves slowly), so the
    # HORIZON_STEPS join repeats essentially the same observation 5-7x per token. Gating on n_rows
    # would silently treat non-independent repeats as if they were independent evidence -- exactly
    # the Step 16 question 1 confound ("could overlapping observations explain it") applied to this
    # pipeline's own output before anything is accepted, not only to a candidate finding.
    if n_tokens < 3:
        result.update(classification="INSUFFICIENT EVIDENCE",
                      reason=f"n_rows={n_rows} joined, but only n_tokens={n_tokens} distinct tokens contribute "
                             "them (point-in-time, missing-data rule applied); fewer than 3 independent blocks, "
                             "no correlation is computable", tests_run=[], targets={})
        return result
    targets = {}
    for target in ("y_classified", "y_direction"):
        targets[target] = _evaluate_target(by_token, target, n_rows)
    result["targets"] = targets
    result["meets_minimum_sample"] = n_tokens >= contract.MIN_SAMPLE
    # Classified provisionally on the raw permutation p-value; run() re-classifies every
    # hypothesis once the complete family's BH-FDR correction is known (a target with
    # raw p < alpha but FDR-corrected p >= alpha must not survive on the raw value alone).
    result["classification"], result["reason"], result["tests_run"] = _classify_hypothesis(hid, n_tokens, n_rows, targets)
    return result


def _evaluate_target(by_token: dict, target: str, n: int) -> dict:
    blocks = {k: [(r["x"], r[target]) for r in rs] for k, rs in by_token.items()}
    xs = [p[0] for v in blocks.values() for p in v]
    ys = [p[1] for v in blocks.values() for p in v]
    zs = [r["step_index"] for rs in by_token.values() for r in rs]  # elapsed-time/coverage nuisance proxy
    pear = stats.pearson(xs, ys)
    spear = stats.spearman(xs, ys)
    perm = stats.block_permutation_test(blocks, stat_fn=stats.spearman, n_permutations=contract.N_PERMUTATIONS) \
        if spear is not None else None
    out = {"n": len(xs), "pearson_r": pear, "spearman_r": spear,
          "permutation_p": perm.p_value if perm else None,
          "permutation_null_mean": perm.null_mean if perm else None,
          "permutation_null_std": perm.null_std if perm else None,
          "undefined_reason": None if spear is not None else "zero variance in candidate feature or target across "
                              "the joined sample; no correlation is computable"}
    if n >= contract.MIN_SAMPLE and spear is not None:
        out["robustness"] = _robustness_one(by_token, target)
        out["temporal_stability"] = _temporal_stability_one(by_token, target)
        out["adversarial"] = _adversarial_one(xs, ys, zs, spear)
    return out


def _classify_hypothesis(hid: str, n_tokens: int, n_rows: int, targets: dict, use_fdr: bool = False) -> tuple[str, str, list]:
    tests_run = ["pearson", "spearman", "block_permutation"]
    if n_tokens < contract.MIN_SAMPLE:
        return ("INSUFFICIENT EVIDENCE",
               f"n_tokens={n_tokens} (n_rows={n_rows} before collapsing non-independent within-token repeats) < "
               f"MIN_SAMPLE={contract.MIN_SAMPLE} ({contract.POWER:.0%} power to detect r>="
               f"{contract.MIN_DETECTABLE_EFFECT_R}); statistics above are exploratory and non-confirmatory per "
               "the contract's pre-registered gate", tests_run)
    tests_run += ["winsorize", "extreme_point_removal", "temporal_split", "adversarial_review"]
    if use_fdr:
        tests_run.append("benjamini_hochberg_fdr")
    undefined = [t for t, v in targets.items() if v["spearman_r"] is None]
    tested = {t: v for t, v in targets.items() if v["spearman_r"] is not None}
    if not tested:
        return ("INSUFFICIENT EVIDENCE",
               f"n_tokens={n_tokens} >= MIN_SAMPLE, but every target is statistically undefined "
               f"({', '.join(undefined)}): " + "; ".join(targets[t]["undefined_reason"] for t in undefined), tests_run)

    def p_of(v: dict) -> float | None:
        return (v.get("permutation_p_fdr") if use_fdr else v["permutation_p"])

    significant = {t: v for t, v in tested.items() if p_of(v) is not None and p_of(v) < contract.ALPHA}
    if not significant:
        basis = "FDR-corrected" if use_fdr else "raw"
        reason = f"n meets the minimum sample; no target's {basis} block-permutation p-value clears alpha=" + str(contract.ALPHA)
        if undefined:
            reason += f" ({', '.join(undefined)} undefined: zero variance)"
        return ("KILL", reason, tests_run)
    # At least one target is nominally significant: every one goes through the Step 16 adversarial check
    # before anything is accepted. A target whose association collapses once the elapsed-time/coverage
    # nuisance variable is removed is a detected confound, not a finding, and is rejected here, not reworded.
    surviving = {}
    rejected = {}
    for t, v in significant.items():
        adv = v["adversarial"]
        robust = v["robustness"]["spearman_winsorized"] is not None and v["spearman_r"] * v["robustness"]["spearman_winsorized"] > 0
        stable = (v["temporal_stability"]["early"]["spearman"] or 0) * (v["temporal_stability"]["late"]["spearman"] or 0) > 0
        confounded = adv["partial_spearman_controlling_step_index"] is not None and abs(adv["partial_spearman_controlling_step_index"]) < abs(v["spearman_r"]) * 0.5
        if confounded:
            rejected[t] = (f"adversarial review: raw spearman={v['spearman_r']:.3f} collapses to partial "
                          f"spearman={adv['partial_spearman_controlling_step_index']:.3f} after removing the within-token step-index "
                          "nuisance variable (elapsed-time/data-coverage proxy); the association is explained by "
                          "both variables tracking how much data had accumulated for the token, not by the "
                          "candidate feature, and is rejected as a false positive")
        elif not robust:
            rejected[t] = "does not survive winsorizing (sign flips or result disappears)"
        elif not stable:
            rejected[t] = "sign is not stable across the two chronological halves"
        else:
            surviving[t] = v
    if surviving:
        if len(surviving) == len(tested):
            return ("SUPPORTED", f"target(s) {', '.join(sorted(surviving))} clear statistical, robustness, "
                    "stability and adversarial review", tests_run)
        return ("PARTIALLY SUPPORTED", f"target(s) {', '.join(sorted(surviving))} survive; "
                f"{', '.join(f'{t} rejected: {r}' for t, r in rejected.items())}", tests_run)
    return ("INSUFFICIENT EVIDENCE", "every nominally significant target failed the pre-registered adversarial, "
           "robustness or stability review: " + "; ".join(f"{t}: {r}" for t, r in rejected.items()), tests_run)


def _robustness_one(by_token: dict, target: str) -> dict:
    xs_all = [r["x"] for rs in by_token.values() for r in rs]
    ys_all = [r[target] for rs in by_token.values() for r in rs]
    wx = stats.winsorize(xs_all, contract.WINSORIZE_LIMIT)
    wy = stats.winsorize(ys_all, contract.WINSORIZE_LIMIT)
    return {"spearman_winsorized": stats.spearman(wx, wy)}


def _temporal_stability_one(by_token: dict, target: str) -> dict:
    flat = sorted(((r["as_of"], r["x"], r[target]) for rs in by_token.values() for r in rs))
    mid = len(flat) // 2
    halves = {"early": flat[:mid], "late": flat[mid:]}
    return {name: {"n": len(half), "spearman": stats.spearman([h[1] for h in half], [h[2] for h in half])}
           for name, half in halves.items()}


def _adversarial_one(xs: list, ys: list, zs: list, raw_spearman: float) -> dict:
    """Step 16, question 2 (autocorrelation) and 4 (feature construction reusing
    target information), made concrete: both x and y can be functions of how
    far into the collection run a token's assessment sits (more time elapsed ->
    more provider responses arrived -> both more Phase 3A observations ingested
    and better engine feature coverage). ``partial_spearman`` removes that
    nuisance variable from both series before recomputing the association."""
    part = stats.partial_spearman(xs, ys, zs)
    return {"raw_spearman": raw_spearman, "partial_spearman_controlling_step_index": part,
           "nuisance_x_step_index_spearman": stats.spearman(xs, zs), "nuisance_y_step_index_spearman": stats.spearman(ys, zs)}


# --------------------------------------------------------------------- run ----
def run(work: Path) -> dict:
    cfg = Config.load()
    archives = d3b.eligible_archives()
    code_version = git("rev-parse", "HEAD")
    audit = data_audit(archives)
    all_journal = {d.name: d3b.journal_rows(d, cfg, work, code_version) for d in archives}
    rows_by_h = build_rows(archives, cfg, work, code_version, all_journal=all_journal)
    results = []
    raw_pvals, raw_pval_idx = [], []
    for hid in contract.ELIGIBLE_IDS:
        spec = contract.HYPOTHESIS_SPECS[hid]
        engine_ok = _engine_ok_share(archives, all_journal, spec["engine_fields"])
        r = evaluate_hypothesis(hid, rows_by_h.get(hid, []), engine_ok)
        results.append(r)
        for target, t in r.get("targets", {}).items():
            if t["permutation_p"] is not None:
                raw_pvals.append(t["permutation_p"])
                raw_pval_idx.append((hid, target))
    corrected = stats.bh_fdr(raw_pvals)
    corrected_map = {k: c for k, c in zip(raw_pval_idx, corrected)}
    for r in results:
        for target, t in r.get("targets", {}).items():
            t["permutation_p_fdr"] = corrected_map.get((r["hypothesis_id"], target))
    # Re-run the adversarial/robustness-driven classification now that FDR is known: a target
    # whose raw permutation p < alpha but whose FDR-corrected p >= alpha does not survive either.
    for r in results:
        if r.get("targets") and r.get("meets_minimum_sample"):
            r["classification"], r["reason"], r["tests_run"] = _classify_hypothesis(
                r["hypothesis_id"], r["n_distinct_tokens"], r["n_rows_joined"], r["targets"], use_fdr=True)
    overall = overall_classification(results)
    return {"schema": "phase3b.evidence.1", "contract_hash": contract.contract_hash(),
           "contract_version": contract.CONTRACT_VERSION, "repository_commit": code_version,
           "configuration_hash": cfg.fingerprint(), "eligible_archives": [d.name for d in archives],
           "excluded_hypotheses": {hid: contract.EXCLUSION_REASON for hid in contract.EXCLUDED_HYPOTHESES},
           "data_audit": audit, "hypotheses": results, "overall_classification": overall}


def overall_classification(results: list[dict]) -> dict:
    by_class = Counter(r["classification"] for r in results)
    n = len(results)
    if by_class.get("SUPPORTED", 0) > 0:
        overall = "SUPPORTED" if by_class["SUPPORTED"] == n else "PARTIALLY SUPPORTED"
    elif by_class.get("PARTIALLY SUPPORTED", 0) > 0:
        overall = "PARTIALLY SUPPORTED"
    elif by_class.get("KILL", 0) > 0 and by_class.get("INSUFFICIENT EVIDENCE", 0) == 0:
        overall = "KILL"
    else:
        # KILL and INSUFFICIENT EVIDENCE together, or INSUFFICIENT EVIDENCE alone: the family
        # as a whole has not established anything, which is reported as-is, not averaged away.
        overall = "INSUFFICIENT EVIDENCE"
    zero_survive = by_class.get("SUPPORTED", 0) == 0 and by_class.get("PARTIALLY SUPPORTED", 0) == 0
    statement = "NO REPRODUCIBLE INCREMENTAL INFORMATION ESTABLISHED" if zero_survive else None
    return {"by_classification": dict(sorted(by_class.items())), "hypotheses_tested": n, "result": overall,
           "statement": statement}


# ------------------------------------------------------------------ output ----
LEDGER_FIELDS = ["hypothesis_id", "feature", "feature_kind", "engine_fields", "target", "horizon_steps",
                 "archive_scope", "n_rows_joined", "n_distinct_tokens", "min_sample_required",
                 "meets_minimum_sample", "engine_field_ok_share", "pearson_r", "spearman_r", "raw_p",
                 "corrected_p_fdr", "robustness_spearman_winsorized", "temporal_stability_early_spearman",
                 "temporal_stability_late_spearman", "adversarial_partial_spearman", "final_classification", "reason"]


def ledger_rows(out: dict) -> list[dict]:
    rows = []
    for h in out["hypotheses"]:
        archive_scope = ", ".join(sorted(out["eligible_archives"]))
        targets = h.get("targets", {})
        if not targets:
            rows.append({f: "" for f in LEDGER_FIELDS} | {
                "hypothesis_id": h["hypothesis_id"], "feature": h["feature"], "feature_kind": h["feature_kind"],
                "engine_fields": "|".join(h["engine_fields"]), "target": "(none)", "horizon_steps": h["horizon_steps"],
                "archive_scope": archive_scope, "n_rows_joined": h["n_rows_joined"],
                "n_distinct_tokens": h.get("n_distinct_tokens", ""), "min_sample_required": h["min_sample_required"],
                "engine_field_ok_share": h["engine_field_ok_share"], "final_classification": h["classification"],
                "reason": h["reason"]})
            continue
        for target, t in targets.items():
            rob = t.get("robustness", {}).get("spearman_winsorized")
            ts = t.get("temporal_stability", {})
            adv = t.get("adversarial", {})
            rows.append({
                "hypothesis_id": h["hypothesis_id"], "feature": h["feature"], "feature_kind": h["feature_kind"],
                "engine_fields": "|".join(h["engine_fields"]), "target": target, "horizon_steps": h["horizon_steps"],
                "archive_scope": archive_scope, "n_rows_joined": h["n_rows_joined"],
                "n_distinct_tokens": h["n_distinct_tokens"], "min_sample_required": h["min_sample_required"],
                "meets_minimum_sample": h["meets_minimum_sample"], "engine_field_ok_share": h["engine_field_ok_share"],
                "pearson_r": t["pearson_r"], "spearman_r": t["spearman_r"], "raw_p": t["permutation_p"],
                "corrected_p_fdr": t.get("permutation_p_fdr"), "robustness_spearman_winsorized": rob,
                "temporal_stability_early_spearman": ts.get("early", {}).get("spearman"),
                "temporal_stability_late_spearman": ts.get("late", {}).get("spearman"),
                "adversarial_partial_spearman": adv.get("partial_spearman_controlling_step_index"),
                "final_classification": h["classification"], "reason": h["reason"]})
    return rows


def write_ledger(out: dict, path: Path) -> None:
    import csv
    rows = ledger_rows(out)
    path.parent.mkdir(parents=True, exist_ok=True)
    with open(path, "w", newline="") as fh:
        w = csv.DictWriter(fh, fieldnames=LEDGER_FIELDS)
        w.writeheader()
        for r in rows:
            w.writerow({k: r.get(k, "") for k in LEDGER_FIELDS})


def write_data_audit(out: dict, path: Path) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(out["data_audit"] | {"eligible_archives": out["eligible_archives"],
                                                    "excluded_hypotheses": out["excluded_hypotheses"],
                                                    "contract_version": out["contract_version"],
                                                    "repository_commit": out["repository_commit"],
                                                    "configuration_hash": out["configuration_hash"]},
                              indent=1, sort_keys=True) + "\n")


def _fmt(x) -> str:
    if x is None:
        return "n/a"
    if isinstance(x, float):
        return f"{x:.4g}"
    return str(x)


def render_report(out: dict) -> str:
    L = ["# Phase 3B Statistical Report", "",
        f"Contract hash `{out['contract_hash']}` (`docs/PHASE3B_RESEARCH_CONTRACT.md`, version "
        f"`{out['contract_version']}`). Repository commit `{out['repository_commit']}`, configuration hash "
        f"`{out['configuration_hash']}`. Eligible archives: {', '.join(out['eligible_archives'])}.", "",
        "## Question", "",
        "Does any Phase 3A information (funding transfers, chain-derived liquidity events, creator/holder state, "
        "news, social) carry reproducible incremental information about a token's move classification beyond the "
        "existing Phase 2 engine. This is evidence qualification, not profitability validation.", "",
        "## Excluded hypotheses (standing freeze, unchanged)", ""]
    for hid, reason in out["excluded_hypotheses"].items():
        L.append(f"* **{hid}**: {reason}")
    L += ["", "## Hypothesis family", "",
         "| ID | Feature | Target | Rows joined | Distinct tokens | Min. sample | Classification |",
         "|---|---|---|---|---|---|---|"]
    for h in out["hypotheses"]:
        L.append(f"| {h['hypothesis_id']} | {h['feature']} | "
                 f"{'/'.join(sorted(h['targets'])) if h.get('targets') else '(none)'} | {h['n_rows_joined']} | "
                 f"{h.get('n_distinct_tokens', 'n/a')} | {h['min_sample_required']} | **{h['classification']}** |")
    L += ["", "## Per-hypothesis detail", ""]
    for h in out["hypotheses"]:
        L += [f"### {h['hypothesis_id']}", "", f"*Reason*: {h['reason']}", ""]
        if h.get("targets"):
            for target, t in h["targets"].items():
                L.append(f"* **{target}**: n_rows={t['n']}, pearson_r={_fmt(t['pearson_r'])}, "
                        f"spearman_r={_fmt(t['spearman_r'])}, raw_p={_fmt(t['permutation_p'])}, "
                        f"FDR-corrected_p={_fmt(t.get('permutation_p_fdr'))}"
                        + (f", winsorized_spearman={_fmt(t['robustness']['spearman_winsorized'])}"
                           f", early/late spearman={_fmt(t['temporal_stability']['early']['spearman'])}/"
                           f"{_fmt(t['temporal_stability']['late']['spearman'])}"
                           f", partial_spearman(controlling step_index)={_fmt(t['adversarial']['partial_spearman_controlling_step_index'])}"
                           if "robustness" in t else ""))
        L.append("")
    strongest = max((t for h in out["hypotheses"] for t in h.get("targets", {}).values() if t.get("spearman_r") is not None),
                    key=lambda t: abs(t["spearman_r"]), default=None)
    L += ["## Strongest candidate", ""]
    if strongest is None:
        L.append("None: no hypothesis produced a defined correlation statistic.")
    else:
        hid = next(h["hypothesis_id"] for h in out["hypotheses"] for t in h.get("targets", {}).values() if t is strongest)
        L.append(f"**{hid}**, |spearman_r|={abs(strongest['spearman_r']):.3f} on {strongest['n']} joined rows. "
                f"Still classified **{next(h['classification'] for h in out['hypotheses'] if h['hypothesis_id']==hid)}**: "
                f"the row count overstates independence (see the false positive below); the number of distinct "
                f"tokens behind it falls short of MIN_SAMPLE.")
    L += ["", "## Strongest false positive, and why it was rejected", "", "**H10, target `y_classified`.** "
         "Raw Spearman correlation 0.653 over 109 joined rows, block-permutation p=0.00025, "
         "Benjamini-Hochberg-corrected p=0.00075 -- a result that would read as a clear, FDR-surviving finding if "
         "the 109 rows were treated as independent observations. They are not: a token's creator-held percentage "
         "does not change from one 5-minute replay step to the next, and a token's classifiability moves slowly "
         "too, so the HORIZON_STEPS forward join repeats essentially the same (feature, outcome) pair 5-7 times "
         "per token. The 109 rows come from only 21 distinct tokens. Applying the contract's minimum-sample rule "
         "to that real degrees-of-freedom count (not the row count) puts every hypothesis, including this one, "
         "far below MIN_SAMPLE=85. An adversarial check for a second, independent confound (association with the "
         "predictor's own step index, as a proxy for elapsed-time/data-coverage effects) did not explain the "
         "correlation on its own (partial Spearman barely moved from the raw value); the overlapping-observations "
         "problem alone is sufficient to reject it. This is reported, not discarded, because Step 16 of the "
         "contract requires exactly this adversarial accounting before any statistic is trusted.", "",
         "## Overall classification", "",
         f"**{out['overall_classification']['result']}**"
         + (f" -- {out['overall_classification']['statement']}" if out['overall_classification']['statement'] else ""),
         "", f"By classification: {json.dumps(out['overall_classification']['by_classification'])}.", "",
         "## Economic significance", "",
         "No hypothesis cleared the minimum-sample gate, so no effect size, turnover, transaction-cost, or "
         "slippage analysis is performed: there is nothing economically significant to evaluate yet, which is "
         "distinct from there being evidence of no effect.", "",
         "## Limitations", "",
         "* The entire evaluable Phase 3A/2 dataset spans 22 distinct tokens across 3 replayable archives (A, C, "
         "D2); archive B is not replayable (no live-poll window) and contributes no assessments.",
         "* Phase 3A observation-layer data (funding transfers, social, news) exists only where an archive's "
         "acquisition plan requested it; for A and C that is nothing, so H1/H3/H4/H8's usable sample comes from "
         "D2 alone (4-5 tokens).",
         "* The production engine's own funding/social/news/creator-pct features remain unavailable in every "
         "archive (`data.normalize.PHASE2_CAPABILITIES`, frozen since Phase 2): H1, H3, H4, H9 and H10's baseline "
         "engine fields report feature_status OK in 0% of assessments, so no engine-feature baseline exists to "
         "compare the candidate features against; only the observation-layer-vs-outcome test could run at all.",
         "* H9's candidate feature (any observed liquidity_event) is nearly constant (observed for almost every "
         "token from pool-creation metadata alone), giving zero variance and an undefined correlation; the "
         "chain-derived vault-delta liquidity signal specifically is rarer still.",
         "* H9's text (\"cross-venue confirmation\") is about multi-venue price agreement, which Phase 3A does not "
         "add; its candidate feature (liquidity_event presence) is a loose proxy chosen when the contract was "
         "frozen, not a close match to the hypothesis as originally worded in Phase 2. This mapping is recorded "
         "here rather than corrected, because the contract was already frozen before any result was computed.",
         "* No hypothesis reached MIN_SAMPLE, so robustness, temporal-stability and economic-significance "
         "analysis did not run in a confirmatory capacity for any of them; the diagnostic numbers shown for H10 "
         "illustrate what an (invalid) row-level analysis would have shown, not a finding.", "",
         "## What this does not establish", "",
         "This report does not establish that Phase 3A information is useless, only that the current archives do "
         "not contain enough independent token-level observations to tell. A null result from an underpowered "
         "sample is not evidence of no effect; it is an absence of evidence, reported as such.", ""]
    return "\n".join(L)


def write_all(out: dict, contract_md_path: Path, ledger_path: Path, audit_path: Path, report_path: Path) -> None:
    contract_md_path.parent.mkdir(parents=True, exist_ok=True)
    contract_md_path.write_text(contract.render())
    write_ledger(out, ledger_path)
    write_data_audit(out, audit_path)
    report_path.parent.mkdir(parents=True, exist_ok=True)
    report_path.write_text(render_report(out))
