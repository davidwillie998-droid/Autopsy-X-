"""Phase 3A observation contract: explicit states, no collapse into 0/false/no, point-in-time visibility."""
import json

import pytest

from autopsyx.core.observation import Availability as A, ContractViolation, Observation, validate
from autopsyx.providers.store import EventStore, decode_record


def obs(**kw):
    base = dict(kind="funding_transfer", entity="W", chain="solana", venue=None, state=A.OBSERVED,
                observation_ts=1_000, source_ts=1_000, source_ts_state=A.OBSERVED, ingestion_ts=2_000,
                provider="solana-rpc", response_status=200, raw_id="r", slot=5, signature="sig",
                value={"program": "system", "source": "S", "destination": "W", "amount": 1.5, "amount_raw": "1500000000",
                       "mint": None, "mint_state": "NOT_APPLICABLE", "tx_status": "success", "signers": ["S"],
                       "fee_payer": "S", "beneficiary": None, "beneficiary_status": "UNKNOWN"})
    base.update(kw)
    return Observation(**base)


def test_valid_observation_passes():
    assert validate(obs()).state == A.OBSERVED


def test_seven_states_exist():
    assert {a.value for a in A} == {"OBSERVED", "NOT_OBSERVED", "UNAVAILABLE", "STALE", "ERROR", "UNKNOWN",
                                    "NOT_APPLICABLE"}


@pytest.mark.parametrize("state", [A.NOT_OBSERVED, A.UNAVAILABLE, A.ERROR, A.UNKNOWN, A.STALE])
def test_non_observed_states_cannot_carry_values(state):
    with pytest.raises(ContractViolation):
        validate(obs(state=state, reason="x"))  # still carries the transfer value
    assert validate(obs(state=state, value={}, reason="provider said nothing")).value == {}


def test_non_observed_states_need_a_reason():
    with pytest.raises(ContractViolation):
        validate(obs(state=A.ERROR, value={}, reason=""))


def test_missing_source_time_must_be_explicit():
    with pytest.raises(ContractViolation):
        validate(obs(source_ts=None))  # state still says OBSERVED
    assert validate(obs(source_ts=None, source_ts_state=A.NOT_OBSERVED)).source_ts is None


def test_value_and_its_state_must_agree():
    v = dict(obs().value, mint=None, mint_state="OBSERVED")
    with pytest.raises(ContractViolation):
        validate(obs(value=v))
    v = dict(obs().value, mint="So11111111111111111111111111111111111111112", mint_state="NOT_APPLICABLE")
    with pytest.raises(ContractViolation):
        validate(obs(value=v))


def test_observed_requires_fields_and_provenance():
    v = dict(obs().value)
    del v["beneficiary_status"]
    with pytest.raises(ContractViolation):
        validate(obs(value=v))
    with pytest.raises(ContractViolation):
        validate(obs(raw_id=None))


def test_provider_cannot_report_future():
    with pytest.raises(ContractViolation):
        validate(obs(source_ts=10_000, ingestion_ts=2_000))


def test_point_in_time_visibility_and_roundtrip(tmp_path):
    s = EventStore()
    early, late = obs(ingestion_ts=2_000), obs(ingestion_ts=9_000, signature="sig2")
    s.extend([early, late])
    assert [o.signature for o in s.view(5_000).observations("funding_transfer")] == ["sig"]
    assert len(s.view(9_000).observations("funding_transfer", "W")) == 2
    EventStore.dump_jsonl(tmp_path / "o.jsonl", [early])
    back = decode_record(json.loads((tmp_path / "o.jsonl").read_text()))
    assert back == early and back.state is A.OBSERVED
