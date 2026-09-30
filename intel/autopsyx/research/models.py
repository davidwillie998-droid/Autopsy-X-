"""Statistical baselines before anything clever.

Purged walk-forward splits (no training sample whose label window overlaps the
test period), an L2 logistic regression, and calibration metrics. Tree models
(LightGBM/XGBoost) plug in through the same ``fit/predict_proba`` shape once
the dependency is justified; a neural net is admissible only if it beats these
out of sample on the same splits.
"""
from __future__ import annotations

import math
from dataclasses import dataclass
from typing import Sequence

TARGETS = ("P_MAJOR_MOVE", "P_CONTINUATION", "P_EXHAUSTION", "P_MANIPULATION", "P_LIQUIDITY_FAILURE")


@dataclass(frozen=True)
class Sample:
    ts: int  # decision time
    label_end_ts: int  # when the label became known
    x: tuple[float, ...]
    y: int


def purged_walk_forward(samples: Sequence[Sample], n_folds: int, embargo_ms: int):
    """Yield (train, test) with train strictly before test, purging samples
    whose label window reaches into the test period plus an embargo."""
    s = sorted(samples, key=lambda x: x.ts)
    fold = len(s) // (n_folds + 1)
    for k in range(1, n_folds + 1):
        test = s[k * fold:(k + 1) * fold]
        if not test:
            break
        t0 = test[0].ts
        train = [x for x in s[:k * fold] if x.label_end_ts + embargo_ms < t0]
        yield train, test


class Logistic:
    def __init__(self, l2: float = 1e-2, lr: float = 0.1, epochs: int = 500):
        self.l2, self.lr, self.epochs = l2, lr, epochs
        self.w: list[float] = []
        self.b = 0.0
        self.mu: list[float] = []
        self.sd: list[float] = []

    def _std(self, x: Sequence[float]) -> list[float]:
        return [(v - m) / s for v, m, s in zip(x, self.mu, self.sd)]

    def fit(self, X: Sequence[Sequence[float]], y: Sequence[int]) -> "Logistic":
        d = len(X[0])
        n = len(X)
        self.mu = [sum(r[j] for r in X) / n for j in range(d)]
        self.sd = [max(1e-9, math.sqrt(sum((r[j] - self.mu[j]) ** 2 for r in X) / n)) for j in range(d)]
        Z = [self._std(r) for r in X]
        self.w, self.b = [0.0] * d, 0.0
        for _ in range(self.epochs):  # deterministic full-batch gradient descent
            gw, gb = [0.0] * d, 0.0
            for z, t in zip(Z, y):
                e = _sig(self.b + sum(a * c for a, c in zip(self.w, z))) - t
                gb += e
                for j in range(d):
                    gw[j] += e * z[j]
            self.b -= self.lr * gb / n
            self.w = [w - self.lr * (g / n + self.l2 * w) for w, g in zip(self.w, gw)]
        return self

    def predict_proba(self, X: Sequence[Sequence[float]]) -> list[float]:
        return [_sig(self.b + sum(a * c for a, c in zip(self.w, self._std(r)))) for r in X]


def _sig(z: float) -> float:
    if z >= 0:
        return 1 / (1 + math.exp(-z))
    e = math.exp(z)
    return e / (1 + e)


def brier(p: Sequence[float], y: Sequence[int]) -> float:
    return sum((a - b) ** 2 for a, b in zip(p, y)) / len(y)


def log_loss(p: Sequence[float], y: Sequence[int], eps: float = 1e-12) -> float:
    return -sum(b * math.log(max(a, eps)) + (1 - b) * math.log(max(1 - a, eps)) for a, b in zip(p, y)) / len(y)


def reliability(p: Sequence[float], y: Sequence[int], bins: int = 10) -> list[tuple[float, float, int]]:
    """(mean predicted, observed frequency, count) per probability bin."""
    out = []
    for i in range(bins):
        lo, hi = i / bins, (i + 1) / bins
        idx = [k for k, v in enumerate(p) if lo <= v < hi or (i == bins - 1 and v == 1.0)]
        if idx:
            out.append((sum(p[k] for k in idx) / len(idx), sum(y[k] for k in idx) / len(idx), len(idx)))
    return out


def evaluate_walk_forward(samples: Sequence[Sample], n_folds: int = 5, embargo_ms: int = 86_400_000) -> dict:
    """Compare the model with the base-rate forecaster on every fold."""
    folds = []
    for train, test in purged_walk_forward(samples, n_folds, embargo_ms):
        if len(train) < 30 or len({s.y for s in train}) < 2:
            continue
        m = Logistic().fit([s.x for s in train], [s.y for s in train])
        p = m.predict_proba([s.x for s in test])
        y = [s.y for s in test]
        base = sum(s.y for s in train) / len(train)
        folds.append({"n_train": len(train), "n_test": len(test), "brier": brier(p, y),
                      "brier_base_rate": brier([base] * len(y), y), "log_loss": log_loss(p, y)})
    return {"folds": folds,
            "beats_base_rate_all_folds": bool(folds) and all(f["brier"] < f["brier_base_rate"] for f in folds)}
