"""Coverage matrix: every cell has a declared state, nothing missing reads as zero."""
from pathlib import Path

from autopsyx.research import phase3a_coverage as cov

from test_phase3a_universe import run3


def test_matrix_has_no_blank_cells_and_declared_states(tmp_path, cfg):
    run3(tmp_path / "d")
    m = cov.matrix([tmp_path / "d"], {"d": {"replayable": True, "identical": True, "observations_identical": True,
                                            "lookahead_all_passed": True}}, cfg)
    assert m["blank_cells"] == 0 and m["row_count"] >= 1
    for r in m["rows"]:
        assert set(r) == set(cov.DIMENSIONS)
        for d in cov.DIMENSIONS:
            assert r[d]["state"] in cov.VOCABULARY[d], (d, r[d])
            if r[d]["state"] not in ("OBSERVED", "VERIFIED", "IDENTITY"):
                assert r[d].get("reason"), (d, r[d])


def test_source_absent_from_plan_is_unavailable_not_zero(cfg):
    root = Path(__file__).resolve().parents[1] / "datasets" / "phase2" / "runs"
    d = root / "gt-sol-20260930c"
    m = cov.matrix([d], {}, cfg)
    for r in m["rows"]:
        for dim in ("funding_transfer", "news", "social"):
            assert r[dim]["state"] == "UNAVAILABLE" and r[dim]["records"] == 0
        assert r["replayability"]["state"] == "NOT_REPLAYABLE"  # no replay result supplied
