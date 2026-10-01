"""Readiness gate and coverage matrix."""
import json
from autopsyx.research import phase3a_readiness as rd

GOOD = {k: True for k in rd.INTEGRITY}
METRICS = {m: 1.0 for m in rd.METRICS} | {"provider_error_rate": 0.0, "multi_day_days": 5, "universe_tokens": 100}


def approved_cfg(**th):
    base = {key: 0.5 for key, _ in rd.METRICS.values()} | {"provider_max_error_rate": 0.1, "multi_day_min_days": 3,
                                                           "universe_min_tokens": 50}
    return {"approved": True, "approved_by": "reviewer", "approved_at": "2026-10-01", "thresholds": base | th}


def test_committed_config_is_unapproved_and_unset():
    cfg = rd.load_config()
    assert cfg["approved"] is False
    assert all(v == "UNSET" for v in cfg["thresholds"].values())
    assert set(cfg["thresholds"]) == {k for k, _ in rd.METRICS.values()}


def test_unapproved_config_is_not_ready_even_with_perfect_inputs():
    g = rd.gate(GOOD, METRICS, rd.load_config())
    assert g["result"] == "NOT_READY"
    assert any("not approved" in r for r in g["reasons"])
    assert sum("UNSET" in r for r in g["reasons"]) == len(rd.METRICS)


def test_approved_and_met_is_ready():
    assert rd.gate(GOOD, METRICS, approved_cfg())["result"] == "READY"


def test_each_failure_named():
    g = rd.gate(GOOD | {"traceability": False}, METRICS | {"news_share": 0.1, "provider_error_rate": 0.5},
                approved_cfg())
    assert g["result"] == "NOT_READY"
    assert any("traceability" in r for r in g["reasons"])
    assert any("news_share" in r for r in g["reasons"]) and any("provider_error_rate" in r for r in g["reasons"])


def test_missing_metric_is_not_a_pass():
    g = rd.gate(GOOD, METRICS | {"social_share": None}, approved_cfg())
    assert g["result"] == "NOT_READY" and any("social_share not observed" in r for r in g["reasons"])


def test_approval_needs_a_name_and_date():
    cfg = approved_cfg()
    cfg["approved_by"] = ""
    assert rd.gate(GOOD, METRICS, cfg)["result"] == "NOT_READY"


def test_gate_is_deterministic():
    a = rd.gate(GOOD, METRICS, rd.load_config())
    b = rd.gate(dict(reversed(list(GOOD.items()))), dict(reversed(list(METRICS.items()))), rd.load_config())
    assert json.dumps(a, sort_keys=True) == json.dumps(b, sort_keys=True)
