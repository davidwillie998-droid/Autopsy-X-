"""Contract tests for point-in-time feature-family ablation."""
import random

import pytest

from autopsyx.research.feature_ablation import (
    AblationSample,
    _purged_grouped_walk_forward,
    evaluate_feature_families,
)


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
            episode_id=f"episode-{i}",
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
    assert a["n_distinct_decision_timestamps"] == 240
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


def test_rejects_non_integer_timestamps_labels_and_fold_settings():
    rows = make_samples()
    rows[0] = AblationSample(**{**rows[0].__dict__, "baseline_ready_ts": True})
    with pytest.raises(ValueError, match="baseline_ready_ts"):
        evaluate_feature_families(rows, n_folds=3, embargo_ms=0, min_train=10)

    rows = make_samples()
    rows[0] = AblationSample(**{**rows[0].__dict__, "y": 1.0})
    with pytest.raises(ValueError, match="labels"):
        evaluate_feature_families(rows, n_folds=3, embargo_ms=0, min_train=10)

    with pytest.raises(ValueError, match="n_folds"):
        evaluate_feature_families(make_samples(), n_folds=True, embargo_ms=0, min_train=10)


def test_equal_decision_timestamps_are_kept_in_one_fold():
    rows = make_samples(180)
    duplicate = AblationSample(
        **{**rows[46].__dict__, "episode_id": "duplicate-episode"}
    )
    rows.append(duplicate)

    folds = list(_purged_grouped_walk_forward(rows, n_folds=3, embargo_ms=0))
    timestamp_fold = {}
    for fold_index, (train, test) in enumerate(folds):
        assert not {sample.ts for sample in train}.intersection(sample.ts for sample in test)
        for sample in test:
            previous = timestamp_fold.setdefault(sample.ts, fold_index)
            assert previous == fold_index

    duplicate_ts = duplicate.ts
    assert sum(sample.ts == duplicate_ts for sample in folds[0][1]) == 2


def test_repeated_token_pool_episode_never_leaks_across_train_and_test():
    rows = make_samples(180)
    rows[50] = AblationSample(
        **{**rows[50].__dict__, "episode_id": rows[0].episode_id}
    )

    for train, test in _purged_grouped_walk_forward(rows, n_folds=3, embargo_ms=0):
        train_episodes = {sample.episode_id for sample in train}
        test_episodes = {sample.episode_id for sample in test}
        assert train_episodes.isdisjoint(test_episodes)


def test_purging_respects_label_resolution_and_embargo():
    rows = make_samples(180)
    boundary = rows[45].ts
    rows[44] = AblationSample(**{**rows[44].__dict__, "label_end_ts": boundary})
    folds = list(_purged_grouped_walk_forward(rows, n_folds=3, embargo_ms=0))
    assert len(folds) == 3
    train, test = folds[0]
    assert all(sample.label_end_ts < min(row.ts for row in test) for sample in train)
