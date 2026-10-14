"""Point-in-time, chronological feature-family ablation for memecoin signals.

This is a research evaluator, not an execution strategy or profitability claim.
Rows are token/pool-episode decision snapshots. Equal decision timestamps are
valid and are kept together when creating chronological folds.
"""
from __future__ import annotations

import math
from dataclasses import dataclass
from typing import Mapping, Sequence

from autopsyx.research.models import Logistic, brier, log_loss


@dataclass(frozen=True)
class AblationSample:
    ts: int
    label_end_ts: int
    episode_id: str
    y: int
    baseline: tuple[float, ...]
    baseline_ready_ts: int
    families: Mapping[str, tuple[float, ...]]
    family_ready_ts: Mapping[str, int]


def _timestamp(value: object, field: str) -> int:
    if isinstance(value, bool) or not isinstance(value, int) or value < 0:
        raise ValueError(f"{field} must be a non-negative integer timestamp in milliseconds")
    return value


def _validate(samples: Sequence[AblationSample]) -> tuple[list[AblationSample], tuple[str, ...]]:
    if len(samples) < 2:
        raise ValueError("at least two samples are required")
    raw_names = tuple(samples[0].families)
    if not raw_names:
        raise ValueError("at least one feature family is required")
    # Validate before sorting: mixed key types otherwise raise an incidental
    # TypeError instead of the evaluator's documented input-validation error.
    if any(not isinstance(name, str) or not name.strip() for name in raw_names):
        raise ValueError("feature-family names must be non-empty strings")
    names = tuple(sorted(raw_names))
    if {"baseline", "combined"}.intersection(names):
        raise ValueError("feature-family names cannot use reserved names 'baseline' or 'combined'")

    baseline_width = len(samples[0].baseline)
    if baseline_width < 1:
        raise ValueError("baseline feature vector cannot be empty")

    for sample in samples:
        ts = _timestamp(sample.ts, "ts")
        label_end_ts = _timestamp(sample.label_end_ts, "label_end_ts")
        baseline_ready_ts = _timestamp(sample.baseline_ready_ts, "baseline_ready_ts")
        if not isinstance(sample.episode_id, str) or not sample.episode_id.strip():
            raise ValueError("episode_id must be a non-empty stable token/pool episode identifier")
        if label_end_ts < ts:
            raise ValueError("label_end_ts cannot precede decision timestamp")
        if baseline_ready_ts > ts:
            raise ValueError("baseline features were not available at decision time")
        if isinstance(sample.y, bool) or not isinstance(sample.y, int) or sample.y not in (0, 1):
            raise ValueError("labels must be integer 0 or 1")
        if len(sample.baseline) != baseline_width or not sample.baseline:
            raise ValueError("baseline feature vectors must have a consistent nonzero width")
        if set(sample.families) != set(names) or set(sample.family_ready_ts) != set(names):
            raise ValueError("all samples must have identical family and readiness keys")

        vectors = [sample.baseline, *(sample.families[name] for name in names)]
        if any(not vector for vector in vectors):
            raise ValueError("feature-family vectors cannot be empty")
        for vector in vectors:
            if any(
                isinstance(value, bool)
                or not isinstance(value, (int, float))
                or not math.isfinite(value)
                for value in vector
            ):
                raise ValueError("features must be finite numeric values")

        for name in names:
            ready_ts = _timestamp(sample.family_ready_ts[name], f"{name}.feature_ready_ts")
            if ready_ts > ts:
                raise ValueError(f"family {name!r} was not available at decision time")
            if len(sample.families[name]) != len(samples[0].families[name]):
                raise ValueError(f"family {name!r} has inconsistent vector width")

    # Equal timestamps are allowed because many tokens can be observed at one
    # decision instant. The fold builder below groups those rows by timestamp.
    return sorted(samples, key=lambda sample: sample.ts), names


def _purged_grouped_walk_forward(
    samples: Sequence[AblationSample], n_folds: int, embargo_ms: int
):
    """Yield chronological folds without splitting timestamp groups or episodes."""
    ordered = sorted(samples, key=lambda sample: sample.ts)
    timestamps = sorted({sample.ts for sample in ordered})
    if n_folds >= len(timestamps):
        raise ValueError("n_folds must be smaller than the number of distinct decision timestamps")
    fold_size = len(timestamps) // (n_folds + 1)

    for fold_index in range(1, n_folds + 1):
        start = fold_index * fold_size
        end = (fold_index + 1) * fold_size
        if fold_index == n_folds:
            end = len(timestamps)
        test_timestamps = timestamps[start:end]
        if not test_timestamps:
            break
        test_start = test_timestamps[0]
        test_timestamp_set = set(test_timestamps)
        test = [sample for sample in ordered if sample.ts in test_timestamp_set]
        test_episodes = {sample.episode_id for sample in test}
        train = [
            sample for sample in ordered
            if sample.ts < test_start
            and sample.label_end_ts + embargo_ms < test_start
            and sample.episode_id not in test_episodes
        ]
        yield train, test


def evaluate_feature_families(
    samples: Sequence[AblationSample],
    n_folds: int = 5,
    embargo_ms: int = 86_400_000,
    min_train: int = 30,
) -> dict:
    """Evaluate baseline, each family added to baseline, and all families.

    Fold metrics are strictly out-of-sample. Training rows are purged when
    their label resolution plus embargo reaches the test period; all rows from
    an episode appearing in the test fold are also excluded from training.
    Negative Brier/log-loss deltas mean the candidate is better than baseline.
    """
    if isinstance(n_folds, bool) or not isinstance(n_folds, int) or n_folds < 1:
        raise ValueError("n_folds must be a positive integer")
    if isinstance(embargo_ms, bool) or not isinstance(embargo_ms, int) or embargo_ms < 0:
        raise ValueError("embargo_ms must be a non-negative integer")
    if isinstance(min_train, bool) or not isinstance(min_train, int) or min_train < 2:
        raise ValueError("min_train must be an integer of at least 2")

    ordered, names = _validate(samples)
    if n_folds >= len({sample.ts for sample in ordered}):
        raise ValueError("n_folds must be smaller than the number of distinct decision timestamps")

    configs: dict[str, tuple[str, ...]] = {"baseline": ()}
    configs.update({name: (name,) for name in names})
    configs["combined"] = names
    out: dict[str, list[dict]] = {name: [] for name in configs}
    skipped = 0

    for train, test in _purged_grouped_walk_forward(ordered, n_folds, embargo_ms):
        if len(train) < min_train or len({sample.y for sample in train}) < 2 or not test:
            skipped += 1
            continue
        test_episodes = {sample.episode_id for sample in test}
        if test_episodes.intersection(sample.episode_id for sample in train):
            raise AssertionError("token/pool episode leaked across a fold")

        for config, included in configs.items():
            def vector(sample: AblationSample) -> tuple[float, ...]:
                parts = [sample.baseline]
                parts.extend(sample.families[name] for name in included)
                return tuple(value for part in parts for value in part)

            model = Logistic().fit([vector(sample) for sample in train], [sample.y for sample in train])
            probabilities = model.predict_proba([vector(sample) for sample in test])
            labels = [sample.y for sample in test]
            out[config].append({
                "n_train": len(train),
                "n_test": len(test),
                "test_start_ts": min(sample.ts for sample in test),
                "test_end_ts": max(sample.ts for sample in test),
                "n_test_timestamps": len({sample.ts for sample in test}),
                "brier": brier(probabilities, labels),
                "log_loss": log_loss(probabilities, labels),
            })

    baseline_by_fold = {i: row for i, row in enumerate(out["baseline"])}
    results = {}
    for config, folds in out.items():
        paired = []
        if config != "baseline" and len(folds) == len(out["baseline"]):
            for i, row in enumerate(folds):
                baseline = baseline_by_fold[i]
                paired.append({
                    "fold": i,
                    "brier_delta": row["brier"] - baseline["brier"],
                    "log_loss_delta": row["log_loss"] - baseline["log_loss"],
                })
        results[config] = {
            "folds": folds,
            "mean_brier": sum(row["brier"] for row in folds) / len(folds) if folds else None,
            "mean_log_loss": sum(row["log_loss"] for row in folds) / len(folds) if folds else None,
            "paired_deltas": paired,
            "beats_baseline_brier_all_folds": bool(paired) and all(row["brier_delta"] < 0 for row in paired),
        }
    return {
        "protocol": "chronological_purged_walk_forward",
        "n_samples": len(ordered),
        "n_distinct_decision_timestamps": len({sample.ts for sample in ordered}),
        "n_folds_requested": n_folds,
        "n_folds_evaluated": len(out["baseline"]),
        "n_folds_skipped": skipped,
        "embargo_ms": embargo_ms,
        "families": list(names),
        "results": results,
        "interpretation": "Research metrics only; not evidence of executable profitability.",
    }
