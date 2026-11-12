"""Adapters from canonical Phase 3A observations into the research PIT contract.

The adapter requires an explicit feature-ready timestamp. The store ingestion
timestamp is not silently treated as feature readiness. Provider payload hashes
are retained as provenance; records without one are rejected.
"""
from __future__ import annotations

import hashlib
import json

from ..core.observation import Observation
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

    source_ts is preferred as event time only when the provider supplied it.
    Otherwise observation_ts is retained as the best-known event time. Chain
    transaction ordering is omitted because the canonical schema does not
    guarantee every ordering index.
    """
    if not isinstance(record, Observation):
        raise TypeError("record must be a canonical Observation")
    if not isinstance(feature_ready_ts, int):
        raise TypeError("feature_ready_ts must be integer milliseconds")
    if not record.raw_id:
        raise ValueError("observation raw_id is required for point-in-time provenance")
    event_ts = record.source_ts if record.source_ts is not None else record.observation_ts
    return EventEnvelope(
        event_id=observation_event_id(record),
        chain=record.chain,
        event_ts=event_ts,
        first_seen_ts=record.ingestion_ts,
        feature_ready_ts=feature_ready_ts,
        payload_hash=record.raw_id,
    )
