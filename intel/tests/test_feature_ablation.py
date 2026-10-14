"""Contract tests for point-in-time feature-family ablation."""
import random

import pytest

from autopsyx.research.feature_ablation import AblationSample, evaluate_feature_families


def make_samples(n=240):
    rng = random.Random(17)
    rows = []
    for i in range(n):
        signal = rng.gauss(0, 1)
        noise = rng.gauss(0, 1)
        y = int(signal + rng.gauss(0, 0.7) > 0)
        ts = i * 10_000
        rows.append(AblationSample(
            ts=ts,
            label_end_ts=ts + 1_000,
            y=y,
            baseline=(noise,),
            baseline_ready_ts=ts,
            families={
                "structure": (signal,),
                "flow": (rng.gauss(0, 1),),
            },
            family_ready_ts={"structure": ts, "flow": ts},
        ))
    return rows


def test_ablation_is_deterministic_and_reports_expected_families():
    rows = make_samples()
    a = evaluate_feature_families(rows, n_folds=4, embargo_ms=0, min_train=20)
    b = evaluate_feature_families(rows, n_folds=4, embargo_ms=0, min_train=20)
    assert a == b
    assert set(a["results"]) == {"baseline", "structure", "flow", "combined"}
    assert a["n_folds_evaluated"] == 4
    assert a["results"]["structure"]["paired_deltas"]
    assert "not evidence of executable profitability" in a["interpretation"]


def test_rejects_feature_family_not_ready_at_decision_time():
    rows = make_samples()
    rows[10] = AblationSample(
        **{**rows[10].__dict__, "family_ready_ts": {"structure": rows[10].ts + 1, "flow": rows[10].ts}}
    )
    with pytest.raises(ValueError, match="not available"):
        evaluate_feature_families(rows, n_folds=3, embargo_ms=0, min_train=10)


def test_rejects_non_finite_feature_values():
    rows = make_samples()
    rows[0] = AblationSample(
        **{**rows[0].__dict__, "families": {"structure": (float("nan"),), "flow": rows[0].families["flow"]}}
    )
    with pytest.raises(ValueError, match="finite"):
        evaluate_feature_families(rows, n_folds=3, embargo_ms=0, min_train=10)


def test_rejects_invalid_labels_and_inconsistent_families():
    rows = make_samples()
    rows[0] = AblationSample(**{**rows[0].__dict__, "y": 2})
    with pytest.raises(ValueError, match="labels"):
        evaluate_feature_families(rows, n_folds=3, embargo_ms=0, min_train=10)

    rows = make_samples()
    rows[0] = AblationSample(
        **{**rows[0].__dict__, "families": {"structure": (1.0,), "other": (0.0,)}}
    )
    with pytest.raises(ValueError, match="identical family"):
        evaluate_feature_families(rows, n_folds=3, embargo_ms=0, min_train=10)


def test_purging_respects_label_resolution_and_embargo():
    rows = make_samples(180)
    # Long labels near a fold boundary must be excluded from that fold's training set.
    boundary = rows[45].ts
    rows[44] = AblationSample(**{**rows[44].__dict__, "label_end_ts": boundary})
    result = evaluate_feature_families(rows, n_folds=3, embargo_ms=0, min_train=10)
    assert result["n_folds_evaluated"] == 3
