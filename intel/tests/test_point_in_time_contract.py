"""Regression tests for the three-clock point-in-time contract."""
import pytest

from autopsyx.research.point_in_time import (
    EventEnvelope,
    FeatureEnvelope,
    build_snapshot,
    validate_contract,
)


def event(event_id="e1", **overrides):
    values = {
        "event_id": event_id,
        "chain": "solana",
        "event_ts": 100,
        "first_seen_ts": 110,
        "feature_ready_ts": 120,
        "payload_hash": "sha256:abc",
        "slot": 10,
        "transaction_index": 2,
        "instruction_index": 1,
        "event_index": 0,
    }
    values.update(overrides)
    return EventEnvelope(**values)


def feature(name="buy_pressure", **overrides):
    values = {
        "name": name,
        "value": 0.72,
        "feature_ready_ts": 130,
        "source_event_ids": ("e1",),
        "version": "v1",
    }
    values.update(overrides)
    return FeatureEnvelope(**values)


def test_accepts_valid_three_clock_snapshot():
    snapshot = build_snapshot([event()], [feature()], decision_ts=140)
    assert snapshot.decision_ts == 140
    assert snapshot.digest and len(snapshot.digest) == 64


@pytest.mark.parametrize(
    ("overrides", "code"),
    [
        ({"event_ts": 111}, "EVENT_AFTER_FIRST_SEEN"),
        ({"first_seen_ts": 121}, "SEEN_AFTER_FEATURE_READY"),
        ({"feature_ready_ts": 141}, "EVENT_NOT_READY"),
        ({"first_seen_ts": 141, "feature_ready_ts": 142}, "EVENT_NOT_OBSERVED"),
        ({"payload_hash": ""}, "MISSING_PAYLOAD_HASH"),
        ({"slot": 10, "transaction_index": None}, "INCOMPLETE_CHAIN_ORDER"),
    ],
)
def test_rejects_invalid_event_chronology_and_lineage(overrides, code):
    issues = validate_contract([event(**overrides)], [], decision_ts=140)
    assert code in {issue.code for issue in issues}


def test_rejects_feature_computed_before_source_was_ready():
    issues = validate_contract(
        [event(feature_ready_ts=125)],
        [feature(feature_ready_ts=124)],
        decision_ts=140,
    )
    assert "FEATURE_BEFORE_SOURCE_READY" in {issue.code for issue in issues}


def test_rejects_feature_ready_after_decision():
    issues = validate_contract([event()], [feature(feature_ready_ts=141)], decision_ts=140)
    assert "FEATURE_NOT_READY" in {issue.code for issue in issues}


def test_rejects_unknown_source_event():
    issues = validate_contract([event()], [feature(source_event_ids=("missing",))], decision_ts=140)
    assert "UNKNOWN_FEATURE_SOURCE" in {issue.code for issue in issues}


def test_chain_order_is_scoped_by_chain():
    rows = [event("a"), event("b", chain="ethereum")]
    assert validate_contract(rows, [], decision_ts=140) == []


def test_duplicate_chain_lineage_is_rejected_within_chain():
    rows = [event("a"), event("b")]
    issues = validate_contract(rows, [], decision_ts=140)
    assert "DUPLICATE_CHAIN_ORDER" in {issue.code for issue in issues}


def test_snapshot_order_and_digest_are_input_order_independent():
    first = event("a", transaction_index=3)
    second = event("b", transaction_index=1)
    features = [feature("z"), feature("a")]
    left = build_snapshot([first, second], features, decision_ts=140)
    right = build_snapshot([second, first], list(reversed(features)), decision_ts=140)
    assert left.digest == right.digest
    assert [row.event_id for row in left.events] == ["b", "a"]
    assert [row.name for row in left.features] == ["a", "z"]


def test_builder_fails_closed_instead_of_dropping_late_data():
    with pytest.raises(ValueError, match="EVENT_NOT_READY"):
        build_snapshot([event(feature_ready_ts=141)], [], decision_ts=140)


def test_rejects_mixed_chain_ordering_modes():
    rows = [event("a"), event("b", slot=None, transaction_index=None,
                         instruction_index=None, event_index=None)]
    issues = validate_contract(rows, [], decision_ts=140)
    assert "MIXED_CHAIN_ORDER_COVERAGE" in {issue.code for issue in issues}


def test_rejects_feature_without_provenance():
    issues = validate_contract([event()], [feature(source_event_ids=())], decision_ts=140)
    assert "FEATURE_WITHOUT_SOURCES" in {issue.code for issue in issues}
