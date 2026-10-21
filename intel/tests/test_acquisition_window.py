"""Regression checks for bounded acquisition lifecycle stages."""
from pathlib import Path


def test_lifecycle_deadlines_bound_setup_polling_and_final_enrichment():
    source = (Path(__file__).parents[1] / "autopsyx" / "data" / "acquire.py").read_text()
    run_body = source[source.index("def run("):]
    discovery_at = run_body.index("if plan.universe_file:")
    setup_deadline_at = run_body.index("setup_deadline = run_started_monotonic + 1200")
    backfill_at = run_body.index("backfill(f, plan, picked)")
    poll_deadline_at = run_body.index("poll_deadline = min(")
    poll_loop_at = run_body.index("while True:", poll_deadline_at)
    final_enrich_at = run_body.index('meta["enrichment"] += enrich(f, plan, picked, 1)')
    lifecycle_deadline_at = run_body.index("lifecycle_deadline = run_started_monotonic + plan.duration_s + 2700")
    assert setup_deadline_at < discovery_at < backfill_at < poll_deadline_at < poll_loop_at
    assert lifecycle_deadline_at < final_enrich_at
    assert "deadline_monotonic=self.deadline_monotonic" in source
    assert '"status": "COMPLETE" if complete else "INCOMPLETE_DEADLINE_OR_WINDOW"' in run_body


def test_poll_window_telemetry_is_persisted():
    source = (Path(__file__).parents[1] / "autopsyx" / "data" / "acquire.py").read_text()
    for field in (
        '"poll_window_started_ms"',
        '"poll_window_duration_s"',
        '"poll_window_cycles"',
        '"poll_window_elapsed_s"',
        '"lifecycle_elapsed_s"',
        '"lifecycle_budget_s"',
        '"setup_budget_s"',
        '"deadline_error"',
    ):
        assert field in source
