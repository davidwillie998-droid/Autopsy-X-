import importlib.util
from pathlib import Path

MODULE = Path(__file__).parents[1] / "autopsyx" / "research" / "phase3c_preflight.py"
spec = importlib.util.spec_from_file_location("phase3c_preflight", MODULE)
module = importlib.util.module_from_spec(spec)
assert spec and spec.loader
spec.loader.exec_module(module)


def good_request():
    return {
        "run_id": "p3c-sol-test",
        "network": "solana",
        "seed": 20261020,
        "strata": {"young": 8, "quiet_young": 4, "trending": 4, "established": 4},
        "new_pool_pages": 3,
        "backfill_pages": 2,
        "duration_s": 7200,
        "cycle_s": 60,
        "poll_ohlcv_limit": 5,
        "poll_pools_per_cycle": 5,
        "ohlcv_every": 1,
        "holders_per_cycle": 2,
        "lag_ms": 60000,
        "gt_rate_per_s": 0.15,
        "gt_min_rate_per_s": 0.05,
        "circuit_waits": 5,
        "rpc_rate_per_s": 2,
        "rpc_max_pages": 1,
        "rpc_max_txs": 8,
        "phase3a": True,
    }


def test_valid_request_passes():
    assert module.validate(good_request()) == []


def test_rejects_undersized_universe():
    request = good_request()
    request["strata"] = {"young": 2, "quiet_young": 1, "trending": 1, "established": 1}
    assert any("below frozen protocol minimum 20" in e for e in module.validate(request))


def test_rejects_boolean_as_integer():
    request = good_request()
    request["duration_s"] = True
    assert any("duration_s" in e for e in module.validate(request))


def test_rejects_changed_poll_frequency():
    request = good_request()
    request["cycle_s"] = 30
    assert any("cycle_s must remain 60" in e for e in module.validate(request))


def test_rejects_missing_enrichment():
    request = good_request()
    request["phase3a"] = False
    assert any("phase3a must be true" in e for e in module.validate(request))



def test_rejects_invalid_poll_budget_before_network_access():
    request = good_request()
    request["poll_pools_per_cycle"] = 0
    assert any("poll_pools_per_cycle must be a positive integer" in e for e in module.validate(request))
    request["poll_pools_per_cycle"] = 21
    assert any("cannot exceed the selected-pool stratum total" in e for e in module.validate(request))


def test_rejects_wrong_chain_scope():
    request = good_request()
    request["network"] = "ethereum"
    assert any("network must remain solana" in e for e in module.validate(request))



def test_frozen_phase3c_request_passes_preflight():
    import json

    frozen_request = Path(__file__).parents[1] / "datasets" / "phase3c" / "REQUEST.json"
    request = json.loads(frozen_request.read_text(encoding="utf-8"))
    assert "rpc_rate_per_s" in request
    assert "rpc_rate" not in request
    assert module.validate(request) == []
