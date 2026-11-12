"""Three-clock point-in-time contract and deterministic snapshot builder.

This module is deliberately provider-neutral. Adapters normalize source events
into EventEnvelope records; feature builders publish FeatureEnvelope records.
A decision snapshot may contain only events and features that were ready by
the decision timestamp. Chain lineage is retained for deterministic ordering.
"""
from __future__ import annotations

import hashlib
import json
from dataclasses import asdict, dataclass
from typing import Any, Iterable


@dataclass(frozen=True)
class EventEnvelope:
    event_id: str
    chain: str
    event_ts: int
    first_seen_ts: int
    feature_ready_ts: int
    payload_hash: str
    slot: int | None = None
    transaction_index: int | None = None
    instruction_index: int | None = None
    event_index: int | None = None


@dataclass(frozen=True)
class FeatureEnvelope:
    name: str
    value: Any
    feature_ready_ts: int
    source_event_ids: tuple[str, ...]
    version: str


@dataclass(frozen=True)
class ContractIssue:
    code: str
    subject: str
    detail: str


@dataclass(frozen=True)
class DecisionSnapshot:
    decision_ts: int
    events: tuple[EventEnvelope, ...]
    features: tuple[FeatureEnvelope, ...]
    digest: str


_LINEAGE_FIELDS = ("slot", "transaction_index", "instruction_index", "event_index")


def event_order_key(event: EventEnvelope) -> tuple:
    """Stable chain order where lineage exists, with a deterministic fallback."""
    if all(getattr(event, field) is not None for field in _LINEAGE_FIELDS):
        return (0, event.chain, *(getattr(event, field) for field in _LINEAGE_FIELDS), event.event_id)
    return (1, event.chain, event.event_ts, event.event_id)


def validate_contract(
    events: Iterable[EventEnvelope],
    features: Iterable[FeatureEnvelope],
    decision_ts: int,
) -> list[ContractIssue]:
    """Return all contract violations; an empty list means the snapshot is admissible."""
    event_rows = list(events)
    feature_rows = list(features)
    issues: list[ContractIssue] = []
    seen_ids: set[str] = set()
    lineage_keys: set[tuple[str, int, int, int, int]] = set()
    lineage_modes: dict[str, set[bool]] = {}

    for event in event_rows:
        if not event.chain:
            issues.append(ContractIssue("EMPTY_CHAIN", event.event_id or "<empty>", "chain is required"))
        if not event.event_id:
            issues.append(ContractIssue("EMPTY_EVENT_ID", "<empty>", "event_id is required"))
        if event.event_id in seen_ids:
            issues.append(ContractIssue("DUPLICATE_EVENT_ID", event.event_id, "event_id must be unique"))
        seen_ids.add(event.event_id)

        if event.event_ts > event.first_seen_ts:
            issues.append(ContractIssue("EVENT_AFTER_FIRST_SEEN", event.event_id,
                                         "event_ts cannot be later than first_seen_ts"))
        if event.first_seen_ts > event.feature_ready_ts:
            issues.append(ContractIssue("SEEN_AFTER_FEATURE_READY", event.event_id,
                                         "first_seen_ts cannot be later than feature_ready_ts"))
        if event.feature_ready_ts > decision_ts:
            issues.append(ContractIssue("EVENT_NOT_READY", event.event_id,
                                         "feature_ready_ts is later than decision_ts"))
        if event.first_seen_ts > decision_ts:
            issues.append(ContractIssue("EVENT_NOT_OBSERVED", event.event_id,
                                         "first_seen_ts is later than decision_ts"))
        if not event.payload_hash:
            issues.append(ContractIssue("MISSING_PAYLOAD_HASH", event.event_id,
                                         "raw payload hash is required for reproducibility"))

        lineage = tuple(getattr(event, field) for field in _LINEAGE_FIELDS)
        present = tuple(value is not None for value in lineage)
        lineage_modes.setdefault(event.chain, set()).add(all(present))
        if any(present) and not all(present):
            issues.append(ContractIssue("INCOMPLETE_CHAIN_ORDER", event.event_id,
                                         "slot and all transaction/instruction indices must be present together"))
        elif all(present):
            if any(not isinstance(value, int) or value < 0 for value in lineage):
                issues.append(ContractIssue("INVALID_CHAIN_ORDER", event.event_id,
                                             "slot and chain indices must be non-negative integers"))
            else:
                scoped_lineage = (event.chain, *lineage)
                if scoped_lineage in lineage_keys:
                    issues.append(ContractIssue("DUPLICATE_CHAIN_ORDER", event.event_id,
                                                "chain lineage tuple must be unique within a snapshot"))
                lineage_keys.add(scoped_lineage)

    for chain, modes in lineage_modes.items():
        if len(modes) > 1:
            issues.append(ContractIssue("MIXED_CHAIN_ORDER_COVERAGE", chain,
                                         "all events for a chain must use lineage ordering or timestamp fallback consistently"))

    event_by_id = {event.event_id: event for event in event_rows}
    feature_names: set[str] = set()
    for feature in feature_rows:
        if not feature.name:
            issues.append(ContractIssue("EMPTY_FEATURE_NAME", "<empty>", "feature name is required"))
        if feature.name in feature_names:
            issues.append(ContractIssue("DUPLICATE_FEATURE", feature.name,
                                         "feature names must be unique within a snapshot"))
        feature_names.add(feature.name)
        if feature.feature_ready_ts > decision_ts:
            issues.append(ContractIssue("FEATURE_NOT_READY", feature.name,
                                         "feature_ready_ts is later than decision_ts"))
        if not feature.version:
            issues.append(ContractIssue("MISSING_FEATURE_VERSION", feature.name,
                                         "feature version is required"))
        if not feature.source_event_ids:
            issues.append(ContractIssue("FEATURE_WITHOUT_SOURCES", feature.name,
                                         "feature provenance must reference at least one source event"))
        for event_id in feature.source_event_ids:
            source = event_by_id.get(event_id)
            if source is None:
                issues.append(ContractIssue("UNKNOWN_FEATURE_SOURCE", feature.name,
                                             f"source event {event_id!r} is absent from the snapshot"))
            elif source.feature_ready_ts > feature.feature_ready_ts:
                issues.append(ContractIssue("FEATURE_BEFORE_SOURCE_READY", feature.name,
                                             f"source event {event_id!r} was not ready when the feature was computed"))
    return issues


def build_snapshot(
    events: Iterable[EventEnvelope],
    features: Iterable[FeatureEnvelope],
    decision_ts: int,
) -> DecisionSnapshot:
    """Build a reproducible snapshot or fail closed with a ValueError."""
    event_rows = tuple(events)
    feature_rows = tuple(features)
    issues = validate_contract(event_rows, feature_rows, decision_ts)
    if issues:
        summary = "; ".join(f"{item.code}:{item.subject}" for item in issues)
        raise ValueError(f"point-in-time contract rejected snapshot: {summary}")

    ordered_events = tuple(sorted(event_rows, key=event_order_key))
    ordered_features = tuple(sorted(feature_rows, key=lambda item: item.name))
    canonical = {
        "decision_ts": decision_ts,
        "events": [asdict(item) for item in ordered_events],
        "features": [asdict(item) for item in ordered_features],
    }
    encoded = json.dumps(canonical, sort_keys=True, separators=(",", ":"), default=str).encode()
    digest = hashlib.sha256(encoded).hexdigest()
    return DecisionSnapshot(decision_ts, ordered_events, ordered_features, digest)
