"""Hard point-in-time guards for research feature inputs.

A feature may be used at decision time only when every source observation
was already received and the feature itself was ready. Event timestamps alone
are insufficient: a historical event received late must not be backfilled into
an earlier decision.
"""
from __future__ import annotations

from dataclasses import dataclass
from typing import Iterable


class PointInTimeViolation(ValueError):
    """Raised when a feature uses information unavailable at decision time."""


def _timestamp(value: int, field: str) -> int:
    # bool is an int subclass, but True/False are not valid millisecond times.
    if isinstance(value, bool) or not isinstance(value, int) or value < 0:
        raise PointInTimeViolation(f"{field} must be a non-negative integer timestamp")
    return value


@dataclass(frozen=True)
class FeatureAvailability:
    """Timing provenance for one computed feature.

    source_seen_ts records when each input became observable to this system,
    not merely when the underlying event allegedly happened.
    """

    name: str
    source_seen_ts: tuple[int, ...]
    feature_ready_ts: int

    def validate_at(self, decision_ts: int) -> None:
        if not self.name or not self.name.strip():
            raise PointInTimeViolation("feature name must not be empty")
        decision = _timestamp(decision_ts, "decision_ts")
        ready = _timestamp(self.feature_ready_ts, "feature_ready_ts")
        if not self.source_seen_ts:
            raise PointInTimeViolation(f"{self.name}: source_seen_ts must not be empty")
        seen = tuple(_timestamp(ts, f"{self.name}.source_seen_ts") for ts in self.source_seen_ts)
        latest_seen = max(seen)
        if latest_seen > ready:
            raise PointInTimeViolation(
                f"{self.name}: feature ready at {ready} precedes latest source availability {latest_seen}"
            )
        if latest_seen > decision:
            raise PointInTimeViolation(
                f"{self.name}: source became available at {latest_seen}, after decision {decision}"
            )
        if ready > decision:
            raise PointInTimeViolation(
                f"{self.name}: feature ready at {ready}, after decision {decision}"
            )


def validate_feature_set(features: Iterable[FeatureAvailability], decision_ts: int) -> None:
    """Validate every feature in a decision snapshot; fail closed on violations."""
    decision = _timestamp(decision_ts, "decision_ts")
    seen_names: set[str] = set()
    for feature in features:
        if feature.name in seen_names:
            raise PointInTimeViolation(f"duplicate feature timing record: {feature.name}")
        seen_names.add(feature.name)
        feature.validate_at(decision)
