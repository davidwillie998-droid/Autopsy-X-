"""Early-life experiment: can the system *safely* make a *useful* assessment of
a token with very little history?

This module measures; it does not classify. It adds no rule and changes no
threshold. Definitions, fixed before any real data was seen:

  SAFE    (invariant S1) no HIGH_CONVICTION_CONTINUATION is ever emitted for an
          assessment whose move class is UNCLASSIFIED or whose data quality
          includes INSUFFICIENT_HISTORY.
  USEFUL  (metric U1, per age bucket) share of assessments that yield a
          classified move (anything but UNCLASSIFIED).
  (metric U2) share of assessments whose Move Quality coverage reaches the
          signal gate's min_coverage.
  (metric U3) share of assessments whose participation baseline is available
          (buyer_growth condition evaluable).

The answer is the table this produces on real replays. A later phase may test
a same-age cohort baseline against these numbers (docs/research/14, H-aux-1).
"""
from __future__ import annotations

from collections import defaultdict
from typing import Iterable

H = 3_600_000
BUCKETS = [("<1h", 0, H), ("1-6h", H, 6 * H), ("6-24h", 6 * H, 24 * H), ("1-7d", 24 * H, 168 * H),
           (">7d", 168 * H, None)]


def bucket(age_ms: int | None) -> str:
    if age_ms is None:
        return "unknown_age"
    for name, lo, hi in BUCKETS:
        if age_ms >= lo and (hi is None or age_ms < hi):
            return name
    return "unknown_age"


def evaluate(records: Iterable[dict], min_coverage: float) -> dict:
    agg: dict[str, dict] = defaultdict(lambda: {"assessments": 0, "tokens": set(), "classified": 0,
                                                "coverage_ok": 0, "participation_evaluable": 0,
                                                "high_conviction": 0, "insufficient_history": 0})
    violations = []
    for r in records:
        b = agg[bucket(r.get("token_age_ms"))]
        b["assessments"] += 1
        b["tokens"].add(r["token"])
        unclassified = r["move_class"] == "UNCLASSIFIED"
        insufficient = "INSUFFICIENT_HISTORY" in r["data_quality"]
        b["classified"] += not unclassified
        b["insufficient_history"] += insufficient
        b["coverage_ok"] += (r.get("move_quality_coverage") or 0) >= min_coverage
        b["participation_evaluable"] += r["conditions"].get("independent_wallet_growth") is not None
        if r["signal"] == "HIGH_CONVICTION_CONTINUATION":
            b["high_conviction"] += 1
            if unclassified or insufficient:
                violations.append({"token": r["token"], "as_of": r["as_of"]})
    table = {}
    order = [n for n, _, _ in BUCKETS] + ["unknown_age"]
    for name in order:
        if name not in agg:
            continue
        b = agg[name]
        n = b["assessments"]
        table[name] = {"assessments": n, "tokens": len(b["tokens"]),
                       "U1_classified_share": b["classified"] / n,
                       "U2_coverage_ok_share": b["coverage_ok"] / n,
                       "U3_participation_evaluable_share": b["participation_evaluable"] / n,
                       "insufficient_history_share": b["insufficient_history"] / n,
                       "high_conviction_signals": b["high_conviction"]}
    return {"S1_safe": not violations, "S1_violations": violations, "S1_violation_count": len(violations), "by_age": table,
            "definitions": __doc__}
