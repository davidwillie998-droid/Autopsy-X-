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
        "strata": {"young": 8, "quiet_young": 4, "trending": 4, "established": 4},
        "duration_s": 7200,
        "cycle_s": 60,
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
