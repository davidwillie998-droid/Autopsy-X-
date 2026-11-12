from dataclasses import replace

import pytest

from autopsyx.core.observation import Availability, Observation
from autopsyx.research.point_in_time import build_snapshot
from autopsyx.research.point_in_time_adapter import adapt_observation, observation_event_id


def sample_observation(**overrides):
    values = dict(
        kind="liquidity_event", entity="MintA", chain="solana", venue="pump.fun",
        state=Availability.OBSERVED, observation_ts=1_000, source_ts=900,
        source_ts_state=Availability.OBSERVED, ingestion_ts=1_100, provider="geyser",
        response_status=200, raw_id="sha256:raw-body", slot=42, signature="sig-1",
        value={"pool": "pool-1", "instruction_index": 2, "inner_index": 0},
    )
    values.update(overrides)
    return Observation(**values)


def test_adapter_preserves_three_clocks_and_raw_provenance():
    record = sample_observation()
    event = adapt_observation(record, feature_ready_ts=1_250)
    assert event.event_ts == 900
    assert event.first_seen_ts == 1_100
    assert event.feature_ready_ts == 1_250
    assert event.payload_hash == "sha256:raw-body"
    assert event.chain == "solana"
    assert event.slot is None  # partial transaction lineage is not fabricated


def test_adapter_uses_observation_time_when_source_time_was_not_supplied():
    record = sample_observation(source_ts=None, source_ts_state=Availability.NOT_OBSERVED)
    event = adapt_observation(record, feature_ready_ts=1_250)
    assert event.event_ts == record.observation_ts


def test_adapter_event_id_is_stable_and_tracks_raw_provenance():
    record = sample_observation()
    assert observation_event_id(record) == observation_event_id(record)
    assert observation_event_id(record) != observation_event_id(replace(record, raw_id="sha256:corrected"))


def test_adapter_requires_real_payload_hash():
    with pytest.raises(ValueError, match="raw_id is required"):
        adapt_observation(sample_observation(raw_id=None), feature_ready_ts=1_250)


def test_decision_snapshot_rejects_feature_ready_after_decision():
    event = adapt_observation(sample_observation(), feature_ready_ts=1_250)
    with pytest.raises(ValueError, match="EVENT_NOT_READY"):
        build_snapshot([event], [], decision_ts=1_200)


def test_decision_snapshot_accepts_observation_only_after_feature_ready():
    event = adapt_observation(sample_observation(), feature_ready_ts=1_250)
    snapshot = build_snapshot([event], [], decision_ts=1_250)
    assert snapshot.events == (event,)
