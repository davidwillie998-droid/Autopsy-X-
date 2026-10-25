"""Phase 3C pipeline correctness and the adversarial data-quality stress
battery (Phase 3C instruction 12): manufactured attacks that must not
produce a passing (REPLICATED EVIDENCE) hypothesis under the frozen rules."""
import math
from collections import defaultdict
from pathlib import Path

import pytest

from autopsyx.research import phase3b_contract as contract
from autopsyx.research import phase3b_stats as stats
from autopsyx.research import phase3c_data as d3c
from autopsyx.research import phase3c_pipeline as p3c


# -------------------------------------------------------- real-data pipeline ----
@pytest.fixture(scope="module")
def evidence(tmp_path_factory):
    return p3c.run(tmp_path_factory.mktemp("phase3c_work"))


def test_reuses_frozen_hypothesis_ids_and_min_sample():
    assert p3c.HYPOTHESIS_IDS is contract.ELIGIBLE_IDS
    assert p3c.MIN_SAMPLE is contract.MIN_SAMPLE


def test_token_level_sample_size_enforced_not_row_count(evidence):
    for h in evidence["hypotheses"]:
        if not h.get("targets"):
            continue
        assert h["n_distinct_tokens"] <= h["n_rows_joined"]
        if h["n_distinct_tokens"] < p3c.MIN_SAMPLE:
            assert h["classification"] == "INSUFFICIENT EVIDENCE"
            assert "MIN_SAMPLE" in h["reason"]


def test_contamination_check_runs_and_reports_structure(evidence):
    c = evidence["contamination"]
    assert "per_archive_token_count" in c and "overlaps" in c and isinstance(c["contamination_free"], bool)


def test_h10_replication_audit_present_and_collapses_to_distinct_tokens(evidence):
    h10 = next(h for h in evidence["hypotheses"] if h["hypothesis_id"] == "H10")
    aud = h10["replication_audit"]
    assert aud["n_tokens_collapsed"] == h10["n_distinct_tokens"]
    for target, t in aud["per_target"].items():
        assert "per_archive" in t


def test_every_hypothesis_classified_one_of_three_states(evidence):
    for h in evidence["hypotheses"]:
        assert h["classification"] in ("REPLICATED EVIDENCE", "FAILED REPLICATION", "INSUFFICIENT EVIDENCE")
        assert "PARTIALLY SUPPORTED" != h["classification"]  # not a terminal Phase 3C state


def test_overall_classification_insufficient_when_nothing_clears_min_sample(evidence):
    assert all(h["n_distinct_tokens"] < p3c.MIN_SAMPLE for h in evidence["hypotheses"])
    assert evidence["overall_classification"]["result"] == "INSUFFICIENT EVIDENCE"


def test_pipeline_deterministic_across_two_runs(tmp_path):
    import json
    out1 = p3c.run(tmp_path / "a")
    out2 = p3c.run(tmp_path / "b")
    strip = lambda o: json.loads(json.dumps(o, sort_keys=True, default=str))
    assert strip(out1) == strip(out2)


# ----------------------------------------------------- adversarial stress battery ----
# These construct synthetic inputs directly against the classifier/stat primitives
# (not against the real archives) to prove each named attack cannot manufacture a
# passing result under the frozen decision rule, independent of what real data shows.

def _fake_target(spearman_r, perm_p, perm_p_fdr, winsorized=None, early=None, late=None,
                 partial_step=None, n=200):
    return {"n": n, "pearson_r": spearman_r, "spearman_r": spearman_r, "permutation_p": perm_p,
           "permutation_p_fdr": perm_p_fdr,
           "robustness": {"spearman_winsorized": winsorized if winsorized is not None else spearman_r},
           "temporal_stability": {"early": {"spearman": early if early is not None else spearman_r},
                                  "late": {"spearman": late if late is not None else spearman_r}},
           "adversarial": {"partial_spearman_controlling_step_index": partial_step if partial_step is not None else spearman_r}}


def test_attack_repeated_horizon_rows_blocked_by_token_gate():
    """Duplicating the same token's row many times inflates n_rows but not
    n_distinct_tokens; the classifier must still refuse it."""
    cls, reason = p3c.classify_hypothesis_3c("H1", n_tokens=5, n_rows=5000,
                                             targets={"y_direction": _fake_target(0.9, 0.0001, 0.0001)},
                                             per_archive={"y_direction": {"a": {"spearman": 0.9, "n_tokens": 5}}}, oos={})
    assert cls == "INSUFFICIENT EVIDENCE" and "MIN_SAMPLE" in reason


def test_attack_archive_pooling_without_agreement_rejected():
    """A pooled significant result where archives disagree in sign must not replicate."""
    per_archive = {"y_direction": {"arch_a": {"spearman": 0.6, "n_tokens": 30},
                                   "arch_b": {"spearman": -0.5, "n_tokens": 30}}}
    cls, reason = p3c.classify_hypothesis_3c("H9", n_tokens=90, n_rows=400,
                                             targets={"y_direction": _fake_target(0.4, 0.001, 0.001)},
                                             per_archive=per_archive, oos={})
    assert cls == "FAILED REPLICATION" and "sign does not agree" in reason


def test_attack_single_archive_result_rejected_without_a_second_agreeing_archive():
    per_archive = {"y_direction": {"only_archive": {"spearman": 0.6, "n_tokens": 90}}}
    cls, reason = p3c.classify_hypothesis_3c("H9", n_tokens=90, n_rows=400,
                                             targets={"y_direction": _fake_target(0.4, 0.001, 0.001)},
                                             per_archive=per_archive, oos={})
    assert cls == "FAILED REPLICATION"


def test_attack_look_ahead_style_confound_detected_via_partial_correlation():
    """A result that collapses once a nuisance variable (standing in for a
    look-ahead/elapsed-time leak) is controlled for must be rejected."""
    per_archive = {"y_direction": {"a": {"spearman": 0.6, "n_tokens": 50}, "b": {"spearman": 0.6, "n_tokens": 50}}}
    cls, reason = p3c.classify_hypothesis_3c("H10", n_tokens=100, n_rows=500,
                                             targets={"y_direction": _fake_target(0.6, 0.0001, 0.0001, partial_step=0.1)},
                                             per_archive=per_archive, oos={})
    assert cls == "FAILED REPLICATION" and "step-index" in reason


def test_attack_fdr_correction_blocks_marginal_raw_significance():
    """Raw p just under alpha but FDR-corrected p over alpha must not pass:
    the classifier gates strictly on the FDR-corrected value."""
    cls, reason = p3c.classify_hypothesis_3c("H8", n_tokens=90, n_rows=400,
                                             targets={"y_direction": _fake_target(0.3, 0.04, 0.12)},
                                             per_archive={"y_direction": {"a": {"spearman": 0.3, "n_tokens": 90}}}, oos={})
    assert cls == "FAILED REPLICATION" and "FDR" in reason


def test_attack_missing_oos_evidence_blocks_replication():
    """Even a result that clears every other gate must not replicate without
    an OOS sign check actually having been computed and agreeing."""
    per_archive = {"y_direction": {"a": {"spearman": 0.6, "n_tokens": 50}, "b": {"spearman": 0.6, "n_tokens": 50}}}
    cls, reason = p3c.classify_hypothesis_3c("H10", n_tokens=100, n_rows=500,
                                             targets={"y_direction": _fake_target(0.6, 0.0001, 0.0001)},
                                             per_archive=per_archive, oos={})  # no OOS entry at all
    assert cls == "FAILED REPLICATION" and "OOS" in reason


def test_attack_oos_sign_disagreement_blocks_replication():
    per_archive = {"y_direction": {"a": {"spearman": 0.6, "n_tokens": 50}, "b": {"spearman": 0.6, "n_tokens": 50}}}
    oos = {"y_direction": {"in_sample": {"sign": 1}, "oos": {"sign": -1}, "signs_agree": False}}
    cls, reason = p3c.classify_hypothesis_3c("H10", n_tokens=100, n_rows=500,
                                             targets={"y_direction": _fake_target(0.6, 0.0001, 0.0001)},
                                             per_archive=per_archive, oos=oos)
    assert cls == "FAILED REPLICATION" and "OOS" in reason


def test_attack_non_robust_result_fails_winsorizing_check():
    per_archive = {"y_direction": {"a": {"spearman": 0.6, "n_tokens": 50}, "b": {"spearman": 0.6, "n_tokens": 50}}}
    cls, reason = p3c.classify_hypothesis_3c("H10", n_tokens=100, n_rows=500,
                                             targets={"y_direction": _fake_target(0.6, 0.0001, 0.0001, winsorized=-0.1)},
                                             per_archive=per_archive, oos={})
    assert cls == "FAILED REPLICATION" and "winsorizing" in reason


def test_genuinely_clean_signal_replicates_under_the_same_frozen_rule():
    """Positive control: when every gate is satisfied, the classifier must say
    REPLICATED EVIDENCE -- proving the gates are strict, not impossible to pass."""
    per_archive = {"y_direction": {"a": {"spearman": 0.6, "n_tokens": 50}, "b": {"spearman": 0.55, "n_tokens": 50}}}
    oos = {"y_direction": {"in_sample": {"sign": 1}, "oos": {"sign": 1}, "signs_agree": True}}
    cls, reason = p3c.classify_hypothesis_3c("H10", n_tokens=100, n_rows=500,
                                             targets={"y_direction": _fake_target(0.6, 0.0001, 0.0001)},
                                             per_archive=per_archive, oos=oos)
    assert cls == "REPLICATED EVIDENCE"


def test_attack_zero_variance_feature_cannot_replicate():
    cls, reason = p3c.classify_hypothesis_3c("H9", n_tokens=90, n_rows=400,
                                             targets={"y_direction": {"spearman_r": None}}, per_archive={}, oos={})
    assert cls == "FAILED REPLICATION" and "undefined" in reason


# -------------------------------------------------- walk-forward OOS mechanics ----
def test_discovery_rows_are_strictly_pre_holdout_and_horizon_purged():
    rows = [
        {"token": f"t{i}", "as_of": step * 1000, "step_index": step,
         "x": float(i + step), "y_direction": float(i + step)}
        for i in range(12) for step in range(20)
    ]
    train, report = p3c.chronological_training_rows(rows)
    assert report["available"] is True
    assert report["cutoff_as_of"] == 10_000
    assert report["n_train_rows_after_purge"] == len(train)
    assert report["n_train_tokens_after_purge"] == 12
    assert train
    assert all(r["as_of"] < report["cutoff_as_of"] for r in train)
    first_oos_step = 10
    assert all(r["step_index"] + contract.HORIZON_STEPS < first_oos_step for r in train)
    assert report["n_train_rows_purged"] > 0



def test_runtime_temporal_isolation_rejects_timestamp_overlap():
    rows = [
        {"token": f"t{i}", "as_of": step * 1000, "step_index": step,
         "x": float(step), "y_direction": float(step)}
        for i in range(4) for step in range(20)
    ]
    train, report = p3c.chronological_training_rows(rows)
    assert report["available"] is True
    # Force a future timestamp into discovery; the runtime guard must fail closed.
    contaminated = [dict(r) for r in train]
    contaminated[0]["as_of"] = report["cutoff_as_of"]
    with pytest.raises(ValueError, match=r"max\(discovery_timestamp\)"):
        p3c.assert_temporal_isolation(rows, contaminated, report)


def test_runtime_temporal_isolation_rejects_label_horizon_overlap():
    rows = [
        {"token": f"t{i}", "as_of": step * 1000, "step_index": step,
         "x": float(step), "y_direction": float(step)}
        for i in range(4) for step in range(20)
    ]
    train, report = p3c.chronological_training_rows(rows)
    assert report["available"] is True
    # Put a row back into discovery that crosses its token's first OOS label horizon.
    token = train[0]["token"]
    contaminated = [dict(r) for r in train]
    bad = dict(next(r for r in rows if r["token"] == token and r["as_of"] < report["cutoff_as_of"]))
    bad["step_index"] = 9
    bad["as_of"] = report["cutoff_as_of"] - 1
    contaminated.append(bad)
    with pytest.raises(ValueError, match="label leakage"):
        p3c.assert_temporal_isolation(rows, contaminated, report)


def test_walk_forward_oos_uses_future_timestamps_and_purges_label_overlap():
    by_token = {
        f"t{i}": [
            {"token": f"t{i}", "as_of": step * 1000, "step_index": step,
             "x": float(i * 100 + step), "y": float(i * 100 + step)}
            for step in range(20)
        ]
        for i in range(12)
    }
    out = p3c.walk_forward_oos(by_token, "y")
    assert out is not None
    assert out["method"] == "chronological_timestamp_split_with_label_horizon_embargo"
    assert out["cutoff_as_of"] == 10_000
    assert out["horizon_steps_embargo"] == contract.HORIZON_STEPS
    assert out["in_sample"]["n_tokens"] == 12
    assert out["oos"]["n_tokens"] == 12
    assert out["in_sample_purged_rows"] > 0
    assert out["signs_agree"] is True


def test_walk_forward_oos_none_when_undefined():
    by_token = {"t1": [{"as_of": 1, "x": 1.0, "y": 1.0}]}
    assert p3c.walk_forward_oos(by_token, "y") is None  # single point: no variance, no sign


# ------------------------------------------------------------- archive-level breakdown ----
def test_per_archive_breakdown_reports_counts_and_correlation():
    rows = [{"archive": "a", "token": "t1", "x": 1.0, "y": 1.0}, {"archive": "a", "token": "t2", "x": 0.0, "y": 0.0},
           {"archive": "b", "token": "t3", "x": 1.0, "y": 0.0}]
    out = p3c.per_archive_breakdown(rows, "y")
    assert out["a"]["n_tokens"] == 2 and out["b"]["n_tokens"] == 1


def test_h10_replication_audit_collapses_deterministically():
    rows = [{"archive": "a", "token": "t1", "step_index": 3, "x": 0.5, "y_classified": 1.0, "y_direction": 1.0},
           {"archive": "a", "token": "t1", "step_index": 1, "x": 0.5, "y_classified": 0.0, "y_direction": -1.0}]
    out = p3c.h10_replication_audit(rows, ["a"])
    assert out["n_tokens_collapsed"] == 1  # one token -> one collapsed row, deterministically the earliest step


# ------------------------------------------------------- contamination dedup ----
def test_deduplicate_rows_keeps_earliest_acquired_archive(tmp_path, monkeypatch):
    """Synthetic contamination: the same bare token address acquired by two
    archives must contribute rows from only the earlier one."""
    class FakeDir:
        def __init__(self, name):
            self.name = name

    monkeypatch.setattr(d3c, "_acquisition_start", lambda d: {"early": 100, "late": 200}[d.name])
    rows = [{"archive": "early", "token": "solana:TOK", "x": 1.0},
           {"archive": "late", "token": "solana:TOK", "x": 2.0},
           {"archive": "early", "token": "solana:OTHER", "x": 3.0}]
    kept, report = d3c.deduplicate_rows_across_archives(rows, [FakeDir("early"), FakeDir("late")])
    assert len(kept) == 2 and all(r["archive"] != "late" or r["token"] != "solana:TOK" for r in kept)
    assert report["dropped"] == [{"token": "TOK", "kept_archive": "early", "dropped_archives": ["late"]}]
    assert report["rows_dropped"] == 1


def test_deduplicate_rows_no_op_without_overlap(tmp_path, monkeypatch):
    class FakeDir:
        def __init__(self, name):
            self.name = name
    monkeypatch.setattr(d3c, "_acquisition_start", lambda d: 0)
    rows = [{"archive": "a", "token": "solana:X", "x": 1.0}, {"archive": "b", "token": "solana:Y", "x": 2.0}]
    kept, report = d3c.deduplicate_rows_across_archives(rows, [FakeDir("a"), FakeDir("b")])
    assert kept == rows and report["rows_dropped"] == 0
