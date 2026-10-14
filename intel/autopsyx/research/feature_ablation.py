"""Point-in-time, chronological feature-family ablation for memecoin signals.

This is a research evaluator, not an execution strategy or profitability claim.
Each feature vector must be available no later than its decision timestamp.
"""
from __future__ import annotations

import math
from dataclasses import dataclass
from typing import Mapping, Sequence

from autopsyx.research.models import Logistic, brier, log_loss, purged_walk_forward


@dataclass(frozen=True)
class AblationSample:
    ts: int
    label_end_ts: int
    y: int
    baseline: tuple[float, ...]
    baseline_ready_ts: int
    families: Mapping[str, tuple[float, ...]]
    family_ready_ts: Mapping[str, int]


def _validate(samples: Sequence[AblationSample]) -> tuple[list[AblationSample], tuple[str, ...]]:
    if len(samples) < 2:
        raise ValueError("at least two samples are required")
    names = tuple(sorted(samples[0].families))
    if not names:
        raise ValueError("at least one feature family is required")
    baseline_width = len(samples[0].baseline)
    if baseline_width < 1:
        raise ValueError("baseline feature vector cannot be empty")
    seen_ts: set[int] = set()
    for s in samples:
        if isinstance(s.ts, bool) or not isinstance(s.ts, int) or isinstance(s.label_end_ts, bool) or not isinstance(s.label_end_ts, int):
            raise ValueError("timestamps must be integer milliseconds")
        if s.ts in seen_ts:
            raise ValueError("decision timestamps must be unique")
        seen_ts.add(s.ts)
        if s.label_end_ts < s.ts:
            raise ValueError("label_end_ts cannot precede decision timestamp")
        if s.y not in (0, 1) or isinstance(s.y, bool):
            raise ValueError("labels must be integer 0 or 1")
        if s.baseline_ready_ts > s.ts:
            raise ValueError("baseline features were not available at decision time")
        if len(s.baseline) != baseline_width or not s.baseline:
            raise ValueError("baseline feature vectors must have a consistent nonzero width")
        if set(s.families) != set(names) or set(s.family_ready_ts) != set(names):
            raise ValueError("all samples must have identical family and readiness keys")
        vectors = [s.baseline, *(s.families[n] for n in names)]
        if any(not v for v in vectors):
            raise ValueError("feature-family vectors cannot be empty")
        for values in vectors:
            if any(not isinstance(v, (int, float)) or isinstance(v, bool) or not math.isfinite(v) for v in values):
                raise ValueError("features must be finite numeric values")
        for name in names:
            if s.family_ready_ts[name] > s.ts:
                raise ValueError(f"family {name!r} was not available at decision time")
            if len(s.families[name]) != len(samples[0].families[name]):
                raise ValueError(f"family {name!r} has inconsistent vector width")
    ordered = sorted(samples, key=lambda s: s.ts)
    return ordered, names


def evaluate_feature_families(
    samples: Sequence[AblationSample],
    n_folds: int = 5,
    embargo_ms: int = 86_400_000,
    min_train: int = 30,
) -> dict:
    """Evaluate baseline, each family added to baseline, and all families.

    Fold metrics are strictly out-of-sample. Purging uses label resolution time
    plus embargo. Family deltas are candidate minus baseline, so negative is
    better for Brier/log-loss. Empty/degenerate folds are skipped explicitly.
    """
    if n_folds < 1 or embargo_ms < 0 or min_train < 2:
        raise ValueError("n_folds and min_train must be positive; embargo_ms cannot be negative")
    ordered, names = _validate(samples)
    configs: dict[str, tuple[str, ...]] = {"baseline": ()}
    configs.update({name: (name,) for name in names})
    configs["combined"] = names
    out: dict[str, list[dict]] = {name: [] for name in configs}
    skipped = 0

    for train, test in purged_walk_forward(ordered, n_folds, embargo_ms):
        if len(train) < min_train or len({s.y for s in train}) < 2 or not test:
            skipped += 1
            continue
        for config, included in configs.items():
            def vector(sample: AblationSample) -> tuple[float, ...]:
                parts = [sample.baseline]
                parts.extend(sample.families[n] for n in included)
                return tuple(v for part in parts for v in part)

            model = Logistic().fit([vector(s) for s in train], [s.y for s in train])
            probs = model.predict_proba([vector(s) for s in test])
            labels = [s.y for s in test]
            out[config].append({
                "n_train": len(train),
                "n_test": len(test),
                "brier": brier(probs, labels),
                "log_loss": log_loss(probs, labels),
            })

    baseline_by_fold = {i: row for i, row in enumerate(out["baseline"])}
    results = {}
    for config, folds in out.items():
        paired = []
        if config != "baseline" and len(folds) == len(out["baseline"]):
            for i, row in enumerate(folds):
                base = baseline_by_fold[i]
                paired.append({
                    "fold": i,
                    "brier_delta": row["brier"] - base["brier"],
                    "log_loss_delta": row["log_loss"] - base["log_loss"],
                })
        results[config] = {
            "folds": folds,
            "mean_brier": sum(x["brier"] for x in folds) / len(folds) if folds else None,
            "mean_log_loss": sum(x["log_loss"] for x in folds) / len(folds) if folds else None,
            "paired_deltas": paired,
            "beats_baseline_brier_all_folds": bool(paired) and all(x["brier_delta"] < 0 for x in paired),
        }
    return {
        "protocol": "chronological_purged_walk_forward",
        "n_samples": len(ordered),
        "n_folds_requested": n_folds,
        "n_folds_evaluated": len(out["baseline"]),
        "n_folds_skipped": skipped,
        "embargo_ms": embargo_ms,
        "families": list(names),
        "results": results,
        "interpretation": "Research metrics only; not evidence of executable profitability.",
    }
