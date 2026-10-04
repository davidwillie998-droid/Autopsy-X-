"""Phase 3B: contract freezing, statistics toolkit, and the research pipeline's
own correctness (unit of analysis, minimum-sample gate, false-positive rejection)."""
import json
import math
from pathlib import Path

import pytest

from autopsyx.research import phase3b_contract as contract
from autopsyx.research import phase3b_pipeline as pl
from autopsyx.research import phase3b_stats as stats

ROOT = Path(__file__).resolve().parents[1]


# ------------------------------------------------------------------ stats ----
def test_pearson_perfect_and_undefined():
    assert stats.pearson([1, 2, 3], [2, 4, 6]) == pytest.approx(1.0)
    assert stats.pearson([1, 2, 3], [3, 2, 1]) == pytest.approx(-1.0)
    assert stats.pearson([1, 1, 1], [1, 2, 3]) is None  # zero variance in x
    assert stats.pearson([1, 2], [1, 2, 3]) is None  # length mismatch
    assert stats.pearson([1], [1]) is None  # n < 2


def test_spearman_handles_ties():
    assert stats.spearman([1, 2, 2, 3], [1, 2, 2, 3]) == pytest.approx(1.0)
    assert stats.rank([1, 2, 2, 4]) == [1.0, 2.5, 2.5, 4.0]


def test_min_sample_for_power_matches_formula():
    from statistics import NormalDist
    r, alpha, power = 0.3, 0.05, 0.8
    c = math.atanh(r)
    expected = math.ceil(((NormalDist().inv_cdf(1 - alpha / 2) + NormalDist().inv_cdf(power)) / c) ** 2 + 3)
    assert stats.min_sample_for_power(r, alpha, power) == expected
    # smaller true effect needs a larger sample
    assert stats.min_sample_for_power(0.2) > stats.min_sample_for_power(0.5)


def test_block_permutation_preserves_within_block_pairing():
    blocks = {"a": [(1.0, 1.0)] * 5, "b": [(0.0, 0.0)] * 5}
    r = stats.block_permutation_test(blocks, n_permutations=200)
    # x and y are perfectly matched within each block; shuffling block order among
    # only 2 blocks can only ever reproduce the same two possible pairings
    assert r is not None and abs(r.observed_stat) == pytest.approx(1.0)


def test_block_permutation_null_is_centered_near_zero_for_unrelated_blocks():
    import random
    rng = random.Random(1)
    blocks = {str(i): [(rng.random(), rng.random()) for _ in range(5)] for i in range(10)}
    r = stats.block_permutation_test(blocks, n_permutations=1000, seed=7)
    assert r is not None and abs(r.null_mean) < 0.2


def test_bh_fdr_monotone_and_bounds():
    raw = [0.001, 0.01, 0.2, 0.5, 0.9]
    corrected = stats.bh_fdr(raw)
    assert len(corrected) == len(raw)
    assert all(c >= r for c, r in zip(corrected, raw))
    assert all(0 <= c <= 1 for c in corrected)
    # corrected p-values must be monotone with respect to rank of raw p-values
    order = sorted(range(len(raw)), key=lambda i: raw[i])
    ordered_corrected = [corrected[i] for i in order]
    assert ordered_corrected == sorted(ordered_corrected)


def test_bh_fdr_empty():
    assert stats.bh_fdr([]) == []


def test_winsorize_clips_extremes_not_middle():
    xs = [1, 2, 3, 4, 5, 6, 7, 8, 9, 100]
    w = stats.winsorize(xs, 0.1)
    assert max(w) < 100 and w[1:9] == xs[1:9]  # the single low and high tail point (k=1) are clipped; the middle is not


def test_residualize_removes_linear_trend():
    z = [0, 1, 2, 3, 4]
    y = [0, 2, 4, 6, 8]  # y = 2*z exactly
    resid = stats.residualize(y, z)
    assert all(abs(r) < 1e-9 for r in resid)


def test_partial_spearman_removes_confound():
    z = list(range(20))
    x = [v + 0.01 for v in z]  # x driven by z
    y = [v * 2 for v in z]     # y driven by z, not by x independently
    raw = stats.spearman(x, y)
    partial = stats.partial_spearman(x, y, z)
    assert raw == pytest.approx(1.0)
    assert partial is None or abs(partial) < 0.5  # confound removed once z is controlled for


# --------------------------------------------------------------- contract ----
def test_contract_is_immutable_shaped_and_hashed():
    text1 = contract.render()
    text2 = contract.render()
    assert text1 == text2  # pure function of frozen module constants
    assert contract.contract_hash() == __import__("hashlib").sha256(text1.encode()).hexdigest()


def test_excluded_hypotheses_match_standing_freeze():
    assert set(contract.EXCLUDED_HYPOTHESES) == {"H2", "H5", "H6", "H7"}
    assert set(contract.ELIGIBLE_IDS) & set(contract.EXCLUDED_HYPOTHESES) == set()


def test_eligible_hypotheses_reuse_phase2_text_verbatim():
    from autopsyx.research.phase2_verify import HYPOTHESES
    by_id = {h[0]: h for h in HYPOTHESES}
    for hid, text, fields, absent in contract.eligible_hypotheses():
        assert (hid, text, fields, absent) == by_id[hid]


def test_min_sample_is_derived_not_hardcoded():
    assert contract.MIN_SAMPLE == stats.min_sample_for_power(contract.MIN_DETECTABLE_EFFECT_R, contract.ALPHA, contract.POWER)


def test_contract_mentions_every_eligible_hypothesis():
    text = contract.render()
    for hid in contract.ELIGIBLE_IDS:
        assert f"| {hid} |" in text
    for hid in contract.EXCLUDED_HYPOTHESES:
        assert hid in text


# -------------------------------------------------------- pipeline (real run) ----
@pytest.fixture(scope="module")
def evidence(tmp_path_factory):
    work = tmp_path_factory.mktemp("phase3b_work")
    return pl.run(work)


def test_eligible_archives_exclude_unverified_original_d():
    names = {d.name for d in pl.d3b.eligible_archives()}
    assert "p3a-sol-20261001d" not in names  # the unhashed original D
    assert "p3a-sol-20261001d2" in names


def test_every_eligible_hypothesis_has_a_ledger_row(evidence):
    tested = {h["hypothesis_id"] for h in evidence["hypotheses"]}
    assert tested == set(contract.ELIGIBLE_IDS)
    for h in evidence["hypotheses"]:
        assert h["classification"] in ("SUPPORTED", "PARTIALLY SUPPORTED", "INSUFFICIENT EVIDENCE", "KILL")
        assert h["reason"]  # never silently omitted


def test_minimum_sample_gate_uses_distinct_tokens_not_rows(evidence):
    """Regression for the bug this run caught: a hypothesis whose forward-joined
    rows exceed MIN_SAMPLE but whose distinct-token count does not must still be
    gated as insufficient -- rows from the same token are not independent."""
    for h in evidence["hypotheses"]:
        if not h.get("targets"):
            continue
        assert h["n_distinct_tokens"] <= h["n_rows_joined"]
        if h["n_distinct_tokens"] < contract.MIN_SAMPLE:
            assert h["classification"] == "INSUFFICIENT EVIDENCE"
            assert "n_tokens=" in h["reason"] or "n_distinct_tokens" in h["reason"] or str(h["n_distinct_tokens"]) in h["reason"]


def test_h10_false_positive_is_named_and_rejected(evidence):
    """The known within-token-repetition false positive: a large, FDR-surviving
    row-level correlation that must not translate into a surviving classification."""
    h10 = next(h for h in evidence["hypotheses"] if h["hypothesis_id"] == "H10")
    yc = h10["targets"]["y_classified"]
    assert yc["spearman_r"] is not None and abs(yc["spearman_r"]) > 0.5
    assert yc["permutation_p_fdr"] is not None and yc["permutation_p_fdr"] < 0.05
    assert h10["n_distinct_tokens"] < contract.MIN_SAMPLE  # why it's rejected
    assert h10["classification"] == "INSUFFICIENT EVIDENCE"


def test_missing_data_never_imputed_as_zero(tmp_path):
    """A row is dropped, not zero-filled, when the candidate feature was never
    ingested for that token by the predictor step."""
    import autopsyx.research.phase3b_pipeline as m
    # a token with no observations at all for the requested kind
    assert m._obs_feature_value([], "funding_transfer", "binary_observed", 10**15) is None


def test_binary_observed_distinguishes_asked_from_never_asked():
    import autopsyx.research.phase3b_pipeline as m
    from autopsyx.core.observation import Availability as A
    from autopsyx.core.observation import Observation

    def obs(state, ts):
        return Observation(kind="news", entity="t", chain="solana", venue=None, state=state, observation_ts=ts,
                           source_ts=None, source_ts_state=A.NOT_OBSERVED, ingestion_ts=ts, provider="p",
                           response_status=200, raw_id="r" if state == A.OBSERVED else None,
                           value={"title": "x", "url": "u", "domain": "d", "content_sha256": "0" * 64,
                                 "publication_time_state": A.NOT_OBSERVED.value, "event_type": "article"}
                           if state == A.OBSERVED else {}, reason="" if state == A.OBSERVED else "none")
    never_asked = []
    asked_absent = [obs(A.NOT_OBSERVED, 100)]
    asked_present = [obs(A.OBSERVED, 100)]
    assert m._obs_feature_value(never_asked, "news", "binary_observed", 200) is None
    assert m._obs_feature_value(asked_absent, "news", "binary_observed", 200) == 0.0
    assert m._obs_feature_value(asked_present, "news", "binary_observed", 200) == 1.0
    # point-in-time: an observation ingested after as_of must not count
    assert m._obs_feature_value(asked_present, "news", "binary_observed", 50) is None


def test_overall_classification_zero_survivors_states_null_result():
    results = [{"classification": "INSUFFICIENT EVIDENCE"}, {"classification": "KILL"}]
    out = pl.overall_classification(results)
    assert out["result"] == "INSUFFICIENT EVIDENCE"
    assert out["statement"] == "NO REPRODUCIBLE INCREMENTAL INFORMATION ESTABLISHED"


def test_overall_classification_all_supported():
    results = [{"classification": "SUPPORTED"}, {"classification": "SUPPORTED"}]
    out = pl.overall_classification(results)
    assert out["result"] == "SUPPORTED" and out["statement"] is None


def test_overall_classification_mixed_supported_and_insufficient():
    results = [{"classification": "SUPPORTED"}, {"classification": "INSUFFICIENT EVIDENCE"}]
    out = pl.overall_classification(results)
    assert out["result"] == "PARTIALLY SUPPORTED"


def test_pipeline_deterministic_across_two_runs(tmp_path):
    out1 = pl.run(tmp_path / "a")
    out2 = pl.run(tmp_path / "b")
    # exclude wall-clock-free but environment-identity fields before comparing
    def strip(o):
        return json.loads(json.dumps(o, sort_keys=True, default=str))
    assert strip(out1) == strip(out2)


def test_ledger_rows_cover_every_hypothesis(evidence):
    rows = pl.ledger_rows(evidence)
    assert {r["hypothesis_id"] for r in rows} == set(contract.ELIGIBLE_IDS)
    assert all(r["reason"] for r in rows)


def test_write_all_is_idempotent_and_reproducible(tmp_path, evidence):
    c1, l1, a1, r1 = (tmp_path / n for n in ("c1.md", "l1.csv", "a1.json", "r1.md"))
    c2, l2, a2, r2 = (tmp_path / n for n in ("c2.md", "l2.csv", "a2.json", "r2.md"))
    pl.write_all(evidence, c1, l1, a1, r1)
    pl.write_all(evidence, c2, l2, a2, r2)
    assert c1.read_text() == c2.read_text()
    assert l1.read_text() == l2.read_text()
    assert r1.read_text() == r2.read_text()


def test_no_production_logic_imported():
    """Phase 3B's own modules must not import anything from signals/risk/ranking/pipeline
    execution paths; it reads replay/journal output, it does not drive the engine."""
    for mod in ("phase3b_contract", "phase3b_stats", "phase3b_data", "phase3b_pipeline"):
        src = (ROOT / "autopsyx" / "research" / f"{mod}.py").read_text()
        for banned in ("signals.entry", "signals.exit", "risk.", "ranking", "CTrade", "place_order", "send_transaction"):
            assert banned not in src, (mod, banned)
