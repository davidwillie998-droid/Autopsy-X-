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


def test_poll_window_telemetry_is_persisted():
    source = (Path(__file__).parents[1] / "autopsyx" / "data" / "acquire.py").read_text()
    for field in (
        '"poll_window_started_ms"',
        '"poll_window_duration_s"',
        '"poll_window_cycles"',
        '"poll_window_elapsed_s"',
    ):
        assert field in source
