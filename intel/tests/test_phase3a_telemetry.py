"""Provider and freshness telemetry from the manifest."""
from autopsyx.core.config import Config
from autopsyx.data.raw import RawStore
from autopsyx.research import phase3a_telemetry as t


def rec(raw, endpoint, req, resp, *, token="T", error=None, status=200, attempts=1, log=(), provider="geckoterminal"):
    raw.record(provider=provider, endpoint=endpoint, url="u", request_ts=req, response_ts=resp, status=status,
               body=None if error else b"{}", attempts=attempts, error=error, context={"token": token},
               attempt_log=list(log))


def test_policy_frozen_and_uses_existing_threshold(cfg):
    p = t.freshness_policy(cfg)
    assert p["max_age_ms"] == cfg.section("data_quality")["max_price_age_ms"] == 120_000
    assert t.policy_freeze(cfg)["identical_to_frozen"]
    changed = Config.load(overrides={"data_quality": {"max_price_age_ms": 60_000}})
    assert not t.policy_freeze(changed)["identical_to_frozen"]


def test_provider_telemetry_counts(tmp_path):
    raw = RawStore(tmp_path)
    rec(raw, "gt.trades", 0, 200, attempts=3, log=[{"status": 429, "error": "HTTPError 429", "wait_s": 2.0, "latency_ms": 50},
                                                  {"status": 503, "error": "HTTPError 503", "wait_s": 4.0, "latency_ms": 60}])
    rec(raw, "gt.trades", 1000, None, error="exhausted", status=None,
        log=[{"status": 429, "error": "x", "wait_s": 1.0, "latency_ms": 1}])
    rec(raw, "gt.trades", 2000, None, error="legacy failure", status=None)  # Phase 2 style: no log
    tel = t.provider_telemetry(raw.entries())["geckoterminal"]
    assert tel["requests"] == 3 and tel["successes"] == 1 and tel["errors"] == 2
    assert tel["error_rate"] == round(2 / 3, 6) and tel["retries_before_success"] == 2
    assert tel["rate_limited_attempts"] == 2 and tel["backoff_s_total"] == 7.0
    assert tel["failures_without_attempt_log"] == 1 and tel["rate_limited_state"] == "PARTIAL"
    assert tel["latency_ms"]["max"] == 200 and tel["status_counts"] == {"200": 1, "none": 2}


def test_freshness_stale_only_where_governed(tmp_path, cfg):
    raw = RawStore(tmp_path)
    for i, req in enumerate([0, 60_000, 300_000]):
        rec(raw, "gt.trades", req, req + 100)
        rec(raw, "gt.token_info", req, req + 100)
    f = t.freshness(raw.entries(), t.freshness_policy(cfg))
    tr = f["endpoints"]["gt.trades"]
    assert tr["evaluations"] == 2 and tr["stale"] == 1 and tr["compliance"] == 0.5
    ti = f["endpoints"]["gt.token_info"]
    assert ti["governed"] is False and ti["stale"] is None and ti["compliance"] == "NOT_APPLICABLE"
    assert f["governed_compliance"] == 0.5


def test_failed_poll_does_not_refresh(tmp_path, cfg):
    raw = RawStore(tmp_path)
    rec(raw, "gt.trades", 0, 100)
    rec(raw, "gt.trades", 60_000, None, error="boom", status=None)
    rec(raw, "gt.trades", 150_000, 150_100)
    f = t.freshness(raw.entries(), t.freshness_policy(cfg))["endpoints"]["gt.trades"]
    assert f["stale"] == 1  # 150_000 - 100 > 120_000 because the 60 s poll failed
