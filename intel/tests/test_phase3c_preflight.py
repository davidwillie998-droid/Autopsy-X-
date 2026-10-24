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
        "strata": {"young": 100, "quiet_young": 20, "trending": 30, "established": 30},
        "new_pool_pages": 3,
        "backfill_pages": 2,
        "duration_s": 7200,
        "cycle_s": 60,
        "poll_ohlcv_limit": 5,
        "poll_pools_per_cycle": 12,
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
    assert any("below distinct-token sample minimum 85" in e for e in module.validate(request))


def test_rejects_universe_that_is_large_enough_but_not_frozen_size():
    request = good_request()
    request["strata"] = {"young": 99, "quiet_young": 20, "trending": 30, "established": 30}
    assert any("frozen universe size 180" in e for e in module.validate(request))


def test_rejects_poll_budget_other_than_frozen_12():
    request = good_request()
    request["poll_pools_per_cycle"] = 11
    assert any("must equal frozen protocol value 12" in e for e in module.validate(request))


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
    request["poll_pools_per_cycle"] = 181
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
    assert module.validate(request, allow_frozen_baseline=True) == []
    assert any("below distinct-token sample minimum 85" in e for e in module.validate(request))



def test_expanded_phase3c_effective_sample_passes_strict_gate():
    request = good_request()
    request["strata"] = {"young": 100, "quiet_young": 20, "trending": 30, "established": 30}
    request["new_pool_pages"] = 10
    request["gt_rate_per_s"] = 0.15
    request["rpc_max_pages"] = 3
    request["rpc_max_txs"] = 8
    assert sum(request["strata"].values()) == 180
    assert request["poll_pools_per_cycle"] == 12
    assert module.validate(request) == []


def test_cli_explicitly_accepts_undersized_frozen_baseline_only(tmp_path, capsys):
    import json

    frozen_request = Path(__file__).parents[1] / "datasets" / "phase3c" / "REQUEST.json"
    request = json.loads(frozen_request.read_text(encoding="utf-8"))
    path = tmp_path / "frozen.json"
    path.write_text(json.dumps(request), encoding="utf-8")
    assert module.main([str(path), "--frozen-baseline"]) == 0
    assert module.main([str(path)]) == 1
    assert "distinct-token sample minimum 85" in capsys.readouterr().err
