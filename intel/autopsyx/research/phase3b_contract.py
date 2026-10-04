"""Phase 3B research contract: frozen before any computation runs.

Hypotheses keep their Phase 2 IDs (``phase2_verify.HYPOTHESES``) and text
verbatim; nothing is renamed, reworded, or renumbered here. H2, H5, H6 and
H7 are excluded by the standing instruction that has applied since Phase 2
("do not test or claim H2, H5, H6, H7") and stay excluded in Phase 3B.

This module is imported by the pipeline to get the frozen hypothesis list,
the frozen minimum-sample rule and the frozen horizon; it is also rendered
to ``docs/PHASE3B_RESEARCH_CONTRACT.md`` and hashed. The hash recorded in
the ledger is of that rendered text, so a later edit to this module (or to
the markdown) is visible as a hash mismatch rather than a silent change.
"""
from __future__ import annotations

import hashlib

from .phase2_verify import HYPOTHESES as PHASE2_HYPOTHESES
from .phase3b_stats import min_sample_for_power

CONTRACT_VERSION = "3b.1"
ALPHA = 0.05
POWER = 0.80
MIN_DETECTABLE_EFFECT_R = 0.30  # moderate correlation; a smaller true effect is not claimed detectable
MIN_SAMPLE = min_sample_for_power(MIN_DETECTABLE_EFFECT_R, ALPHA, POWER)  # 85, from the Fisher-z formula
HORIZON_STEPS = 3  # forward join distance in replay steps (5 min/step -> 15 minutes ahead)
N_PERMUTATIONS = 4000
WINSORIZE_LIMIT = 0.10
EXCLUDED_HYPOTHESES = ("H2", "H5", "H6", "H7")
EXCLUSION_REASON = ("frozen by the standing instruction carried from Phase 2 through Phase 3A: "
                    "\"do not test or claim H2, H5, H6 or H7\"; Phase 3B does not lift it")

# Candidate Phase 3A observation feature per eligible hypothesis, and how it is
# read from the observation layer (never from the production engine's own
# FundingTransfer/LiquidityEvent/SocialPost/NewsEvent records, which Phase 3A
# never populated -- that separation is the frozen Phase 3A architecture).
# "binary_observed": 1 if an OBSERVED record of that kind exists for the token
#   by the assessment time, else 0; never NOT_OBSERVED/UNAVAILABLE/ERROR -> 1.
# "creator_pct" / "top10_share": the value.* field when creator_state/holder_state
#   is KNOWN_AT_ASSESSMENT at the assessment time (core.observation.Availability),
#   else the row is dropped for that hypothesis (not imputed as 0).
HYPOTHESIS_SPECS = {
    "H1": {"observation_feature": "funding_transfer", "feature_kind": "binary_observed",
          "engine_fields": ("unique_buyers", "independence_ratio")},
    "H3": {"observation_feature": "social", "feature_kind": "binary_observed",
          "engine_fields": ("social_mentions", "independence_ratio")},
    "H4": {"observation_feature": "social", "feature_kind": "binary_observed",
          "engine_fields": ("social_mentions", "buyer_growth")},
    "H8": {"observation_feature": "news", "feature_kind": "binary_observed", "engine_fields": ()},
    "H9": {"observation_feature": "liquidity_event", "feature_kind": "binary_observed",
          "engine_fields": ("cross_venue",)},
    "H10": {"observation_feature": "creator_state", "feature_kind": "creator_pct",
           "engine_fields": ("price_z_driving", "unique_buyers", "social_mentions", "creator_pct")},
}
ELIGIBLE_IDS = tuple(HYPOTHESIS_SPECS)

TARGETS = {
    "classified": "1 if move_class at t+HORIZON_STEPS != 'UNCLASSIFIED' else 0 (binary; existing production "
                 "classification, not recomputed)",
    "direction": "move_direction at t+HORIZON_STEPS (existing production field, signed numeric)",
}


def eligible_hypotheses() -> list[tuple[str, str, tuple, str | None]]:
    by_id = {h[0]: h for h in PHASE2_HYPOTHESES}
    return [by_id[hid] for hid in ELIGIBLE_IDS]


CONTRACT_MARKDOWN = None  # filled by render() below; kept as a function, not a stored global, to avoid staleness


def render() -> str:
    L = ["# Phase 3B Research Contract", "",
        f"Version `{CONTRACT_VERSION}`. Frozen before Step 2 (data audit) runs; the hash of this exact text is "
        "recorded in the research ledger and in `research/phase3b/results/phase3b_data_audit.json`. No hypothesis "
        "listed here may be added, removed, or reworded after a result is seen.", "",
        "## Scope", "",
        "Phase 3B asks one question: does any Phase 3A information (funding transfers, chain-derived liquidity "
        "events, creator/holder state, news, social) carry reproducible incremental information about a token's "
        "move classification beyond what the existing Phase 2 engine already computes from GeckoTerminal and "
        "DexScreener market data. It is evidence qualification, not profitability validation, and it does not "
        "touch signal thresholds, weights, entry/exit logic, risk logic, or the production EA.", "",
        "## Unit of analysis", "",
        "One row is one (archive, token, assessment step, forward step) tuple: the replay engine's own "
        "point-in-time assessment of a token at step *t*, joined to its own assessment of the same token at step "
        "*t + HORIZON_STEPS*. Assessments come from re-running the frozen `replay.run()` over the frozen "
        "`data.normalize.normalize()` output of each eligible archive, at the frozen replay cadence "
        "(`step_ms = 5*60_000`) `phase3a_verify.replay_archive` already uses; nothing about normalization or "
        "replay is changed for Phase 3B.", "",
        f"## Prediction horizon", "", f"`HORIZON_STEPS = {HORIZON_STEPS}` replay steps (15 minutes at the "
        "5-minute replay cadence). One horizon, fixed before any feature or target is computed; no horizon search.", "",
        "## Targets", ""]
    for k, v in TARGETS.items():
        L.append(f"* **{k}**: {v}")
    L += ["", "Both targets are read from the production journal's own `move_class`/`move_direction` fields. "
         "Phase 3B computes neither; it only joins across time.", "",
         "## Baseline", "",
         "The baseline is the production engine's own classification using only Phase 2 market data: the "
         "`feature_status` of each hypothesis's engine fields (OK vs MISSING/STALE/INSUFFICIENT_HISTORY/etc.) at "
         "the predictor step *t*, exactly as the frozen engine already reports it. Phase 3B does not build a new "
         "baseline model; it measures whether a Phase 3A observation feature adds anything to a case the engine "
         "already decided (or could have decided, had the field been available).", "",
         "## Candidate features and hypotheses", "",
         f"Eligible: {', '.join(ELIGIBLE_IDS)}. Excluded, standing freeze: {', '.join(EXCLUDED_HYPOTHESES)} "
         f"({EXCLUSION_REASON}).", "",
         "| ID | Text | Engine fields (baseline) | Candidate Phase 3A feature | Kind |",
         "|---|---|---|---|---|"]
    for hid, text, fields, _absent in eligible_hypotheses():
        spec = HYPOTHESIS_SPECS[hid]
        L.append(f"| {hid} | {text} | {', '.join(fields) or '(none)'} | {spec['observation_feature']} | "
                 f"{spec['feature_kind']} |")
    L += ["", "A candidate feature is read strictly point-in-time: an observation counts only when its "
         "`ingestion_ts` is at or before the predictor step's `as_of`; a record ingested later is invisible, "
         "exactly as `providers.store.PointInTimeView` already enforces for every other record type.", "",
         "## Missing-data rule", "",
         "Never substitute zero, a forward fill, or a synthetic value for a missing observation. A row whose "
         "candidate feature was never OBSERVED by the predictor step, or whose creator/holder state is not "
         "KNOWN_AT_ASSESSMENT, is dropped from that hypothesis's sample; it is not counted as a negative "
         "observation of the feature.", "",
         "## Minimum sample requirement", "",
         f"Derived, not asserted: the smallest *n* giving {POWER:.0%} power to detect a two-sided Pearson/Spearman "
         f"correlation of at least {MIN_DETECTABLE_EFFECT_R} at alpha={ALPHA}, via the Fisher-z approximation "
         "`n = ((z_(1-alpha/2) + z_power) / atanh(r))^2 + 3`, giving **"
         f"MIN_SAMPLE = {MIN_SAMPLE}**. A hypothesis whose usable sample (after the missing-data rule) is below "
         "this is classified INSUFFICIENT EVIDENCE regardless of any nominal p-value computed from it; the "
         "statistic is still reported, labelled exploratory and non-confirmatory, never as a finding. Because a "
         "token's candidate feature value and its classifiability both change slowly relative to "
         "HORIZON_STEPS, MIN_SAMPLE is applied to the number of **distinct tokens** contributing joined rows to a "
         "hypothesis, not to the row count after the horizon join: counting repeated near-constant per-token "
         "observations as independent rows would understate how little information the sample actually carries.", "",
         "## Statistical tests", "",
         "Pearson and Spearman correlation between the candidate feature value (or its 0/1 presence) and the "
         "forward target, computed on the pooled sample. Significance is judged by a block permutation null "
         "(`phase3b_stats.block_permutation_test`): the pairing of a token's own feature sequence with a token's "
         "own target sequence is permuted across tokens, never within a token, so each token's own "
         "autocorrelation is preserved and only cross-token association is tested against chance. A naive IID "
         "permutation or t-test is not used, because the rows are overlapping, serially dependent assessments of "
         "a small number of tokens, not independent draws.", "",
         "## Multiple-testing correction", "",
         "Benjamini-Hochberg FDR (`phase3b_stats.bh_fdr`) over every raw p-value produced across the complete "
         "tested family (every hypothesis with n >= 3, whether or not it clears MIN_SAMPLE). No p-value is "
         "reported or interpreted without its corrected counterpart next to it.", "",
         "## Robustness and temporal stability", "",
         f"For a hypothesis whose sample clears MIN_SAMPLE: recompute on winsorized data "
         f"(`WINSORIZE_LIMIT = {WINSORIZE_LIMIT}`) and on the raw data with the single most extreme |residual| "
         "observation removed; a result that depends on either is downgraded. Temporal stability is checked by "
         "splitting the pooled sample at its chronological midpoint and requiring the same sign in both halves, "
         "each with its own n; this step does not run on an already-INSUFFICIENT-EVIDENCE hypothesis, since there "
         "is nothing to stabilize on fewer than MIN_SAMPLE observations.", "",
         "## Acceptance criteria", "",
         "SUPPORTED: n >= MIN_SAMPLE, raw p < alpha, BH-corrected p < alpha, block-permutation p < alpha, "
         "survives winsorizing and extreme-point removal, same sign in both chronological halves. PARTIALLY "
         "SUPPORTED: clears the statistical tests but fails a robustness or stability check, or the economic "
         "magnitude is negligible. INSUFFICIENT EVIDENCE: n < MIN_SAMPLE, or any required input is UNAVAILABLE "
         "for every archive. KILL: n >= MIN_SAMPLE and the result is a precise, stable null (corrected p far from "
         "significant with a tight confidence interval around zero), not merely untested.", "",
         "## Kill criteria", "",
         "A hypothesis whose required engine fields report feature_status OK in 0% of all eligible assessments, "
         "in every archive, is recorded but not run through the ablation/permutation/stability steps: there is no "
         "baseline to compare against, and the conclusion (INSUFFICIENT EVIDENCE) is already determined by the "
         "frozen Phase 2 capability flags (`data.normalize.PHASE2_CAPABILITIES`), unchanged since Phase 2.", "",
         "## Reporting rules", "",
         "Every hypothesis in `ELIGIBLE_IDS` is reported, including every one that fails at the data-audit or "
         "minimum-sample stage. No result is omitted for being null. The overall Phase 3B classification is the "
         "one driven by the complete family (Step 19), never by the single most favorable hypothesis.", ""]
    return "\n".join(L)


def contract_hash() -> str:
    return hashlib.sha256(render().encode()).hexdigest()
