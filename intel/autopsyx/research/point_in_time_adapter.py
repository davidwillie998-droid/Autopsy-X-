"""Adapters from canonical Phase 3A observations into the research PIT contract.

The adapter requires an explicit provider event timestamp and feature-ready
timestamp. It never substitutes local observation or ingestion time for source
event time. Provider raw identifiers are retained as provenance.
"""
from __future__ import annotations

import hashlib
import json

from ..core.observation import Availability, Observation
from .point_in_time import EventEnvelope


def observation_event_id(record: Observation) -> str:
    """Return a stable identifier tied to canonical identity and raw provenance."""
    identity = {
        "kind": record.kind,
        "chain": record.chain,
        "entity": record.entity,
        "uid": list(record.uid),
        "provider": record.provider,
        "raw_id": record.raw_id,
    }
    encoded = json.dumps(identity, sort_keys=True, separators=(",", ":"), default=str).encode()
    return hashlib.sha256(encoded).hexdigest()


def adapt_observation(record: Observation, *, feature_ready_ts: int) -> EventEnvelope:
    """Convert one canonical observation without inventing missing timestamps.

    A canonical observation may carry a best-known observation_ts even when
    the provider did not supply the actual event/publication time. That value
    is not admissible as event_ts for point-in-time research. Such records
    remain available in the canonical store but must not enter this strict
    event envelope until source time is observed.
    """
    if not isinstance(record, Observation):
        raise TypeError("record must be a canonical Observation")
    if type(feature_ready_ts) is not int:
        raise TypeError("feature_ready_ts must be integer milliseconds")
    if (record.source_ts is None) != (record.source_ts_state != Availability.OBSERVED):
        raise ValueError("source_ts and source_ts_state disagree")
    if record.source_ts is None:
        raise ValueError("source event timestamp is required for point-in-time admission")
    if not record.raw_id:
        raise ValueError("observation raw_id is required for point-in-time provenance")
    return EventEnvelope(
        event_id=observation_event_id(record),
        chain=record.chain,
        event_ts=record.source_ts,
        first_seen_ts=record.ingestion_ts,
        feature_ready_ts=feature_ready_ts,
        payload_hash=record.raw_id,
    )
