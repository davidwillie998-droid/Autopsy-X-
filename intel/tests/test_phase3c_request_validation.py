import pytest

from autopsyx.data.request_validation import (
    distinct_token_count,
    validate_minimum_strata,
    validate_phase3c_request,
)


def valid_request():
    return {
        "run_id": "p3c-sol-test001",
        "network": "solana",
        "seed": 20261020,
        "strata": {
            "young": 8,
            "quiet_young": 4,
            "trending": 6,
            "established": 6,
        },
    }


def test_phase3c_request_accepts_at_least_frozen_minimum():
    assert validate_phase3c_request(valid_request(), 20) == 24


def test_phase3c_rejects_strata_target_below_selected_minimum():
    request = valid_request()
    request["min_selected_tokens"] = 25
    with pytest.raises(ValueError, match="below min_selected_tokens 25"):
        validate_phase3c_request(request, 20)


def test_phase3c_request_rejects_undersized_universe():
    request = valid_request()
    request["strata"] = {
        "young": 2, "quiet_young": 1, "trending": 1, "established": 1
    }
    with pytest.raises(ValueError, match="requires at least 20"):
        validate_phase3c_request(request, 20)


@pytest.mark.parametrize("strata", [
    None,
    {"young": 5, "quiet_young": 5, "trending": 5},
    {"young": 5, "quiet_young": 5, "trending": 5, "established": 5, "other": 1},
    {"young": True, "quiet_young": 5, "trending": 5, "established": 5},
    {"young": -1, "quiet_young": 6, "trending": 6, "established": 6},
])
def test_invalid_strata_fail_closed(strata):
    with pytest.raises(ValueError):
        validate_minimum_strata(strata, 20)


def test_phase3c_rejects_scope_and_unsafe_run_id():
    request = valid_request()
    request["network"] = "ethereum"
    with pytest.raises(ValueError, match="frozen to network"):
        validate_phase3c_request(request, 20)
    request = valid_request()
    request["run_id"] = "../overwrite"
    with pytest.raises(ValueError, match="safe filename"):
        validate_phase3c_request(request, 20)


def test_count_distinct_token_addresses_not_pool_rows():
    picked = [
        {"pool": "pool-a", "token": "token-1"},
        {"pool": "pool-b", "token": "token-1"},
        {"pool": "pool-c", "token": "token-2"},
        {"pool": "pool-d", "token": ""},
        {"pool": "pool-e"},
    ]
    assert distinct_token_count(picked) == 2
