"""Regression checks for the live-observation budget placement.

This architecture test protects against discovery/backfill/enrichment silently
consuming the configured real-time polling window again."""
from pathlib import Path


def test_live_poll_clock_starts_after_setup_stages():
    source = (Path(__file__).parents[1] / "autopsyx" / "data" / "acquire.py").read_text()
    run_body = source[source.index("def run("):]
    backfill_at = run_body.index("    backfill(f, plan, picked)")
    initial_enrich_at = run_body.index('meta["enrichment"] = enrich(f, plan, picked, 0)')
    clock_at = run_body.index("poll_window_started_ms = now_ms()")
    loop_at = run_body.index("while True:", clock_at)
    assert backfill_at < clock_at < loop_at
    assert initial_enrich_at < clock_at
    assert "(t0 - poll_window_started_ms) / 1000 >= plan.duration_s" in run_body




def test_phase3c_workflow_passes_explicit_restart_reason_to_collector():
    workflow = (Path(__file__).parents[2] / ".github" / "workflows" / "phase3c-acquire.yml").read_text()
    assert "restart_reason:" in workflow
    assert "AUTOPSYX_RESTART_REASON: ${{ inputs.restart_reason || 'trigger did not supply a restart reason' }}" in workflow

def test_poll_window_telemetry_is_persisted():
    source = (Path(__file__).parents[1] / "autopsyx" / "data" / "acquire.py").read_text()
    for field in (
        '"poll_window_started_ms"',
        '"poll_window_ended_ms"',
        '"poll_window_duration_s"',
        '"poll_window_cycles"',
        '"poll_window_elapsed_s"',
    ):
        assert field in source


def test_collector_segment_records_immutable_workflow_identity(monkeypatch):
    from autopsyx.data.acquire import _segment_metadata

    monkeypatch.setenv("GITHUB_RUN_ID", "12345")
    monkeypatch.setenv("GITHUB_RUN_ATTEMPT", "2")
    monkeypatch.setenv("GITHUB_EVENT_NAME", "workflow_dispatch")
    monkeypatch.setenv("GITHUB_SHA", "abc123")
    monkeypatch.setenv("AUTOPSYX_RESTART_REASON", "manual restart after provider outage")

    segment = _segment_metadata(1_800_000_000_000)["acquisition_segment"]
    assert segment == {
        "segment_id": "12345.2",
        "workflow_run_id": "12345",
        "workflow_run_attempt": "2",
        "event": "workflow_dispatch",
        "commit_sha": "abc123",
        "restart_reason": "manual restart after provider outage",
        "started_ms": 1_800_000_000_000,
    }


def test_collector_segment_does_not_invent_missing_restart_reason(monkeypatch):
    from autopsyx.data.acquire import _segment_metadata

    for name in ("GITHUB_RUN_ID", "GITHUB_RUN_ATTEMPT", "GITHUB_EVENT_NAME", "GITHUB_SHA", "AUTOPSYX_RESTART_REASON"):
        monkeypatch.delenv(name, raising=False)
    segment = _segment_metadata(123)["acquisition_segment"]
    assert segment["segment_id"] is None
    assert segment["restart_reason"] == "not_provided"
    assert segment["commit_sha"] == "local"
