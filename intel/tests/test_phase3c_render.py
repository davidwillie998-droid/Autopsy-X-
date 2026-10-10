"""Phase 3C renderers: pure functions of the evidence dict, deterministic,
and write_all produces every required deliverable path."""
from pathlib import Path

import pytest

from autopsyx.research import phase3c_pipeline as p3c
from autopsyx.research import phase3c_render as r3c


@pytest.fixture(scope="module")
def evidence(tmp_path_factory):
    return p3c.run(tmp_path_factory.mktemp("phase3c_render_work"))


@pytest.mark.parametrize("fn", [r3c.render_data_audit, r3c.render_provenance_report, r3c.render_statistical_report,
                                r3c.render_replication_report, r3c.render_system_status])
def test_renderer_is_a_pure_function_of_the_evidence(evidence, fn):
    assert fn(evidence) == fn(evidence)


def test_statistical_report_mentions_every_hypothesis(evidence):
    text = r3c.render_statistical_report(evidence)
    for hid in p3c.HYPOTHESIS_IDS:
        assert hid in text


def test_replication_report_is_about_h10(evidence):
    text = r3c.render_replication_report(evidence)
    assert "H10" in text or "classification" in text.lower()
    assert "one-row-per-token" in text or "one row per token" in text


def test_write_all_creates_every_required_deliverable(tmp_path, evidence):
    r3c.write_all(evidence, tmp_path)
    for rel in ("docs/PHASE3C_DATA_AUDIT.md", "docs/PHASE3C_PROVENANCE_REPORT.md",
               "docs/PHASE3C_STATISTICAL_REPORT.md", "docs/PHASE3C_REPLICATION_REPORT.md",
               "docs/PHASE3C_SYSTEM_STATUS.md", "research/phase3c/evidence.json",
               "research/phase3c/phase3c_research_ledger.csv"):
        p = tmp_path / rel
        assert p.exists() and p.stat().st_size > 0, rel


def test_write_all_is_reproducible(tmp_path, evidence):
    d1, d2 = tmp_path / "1", tmp_path / "2"
    for d in (d1, d2):
        (d / "docs").mkdir(parents=True)
        (d / "research" / "phase3c").mkdir(parents=True)
    r3c.write_all(evidence, d1)
    r3c.write_all(evidence, d2)
    for rel in ("docs/PHASE3C_DATA_AUDIT.md", "docs/PHASE3C_STATISTICAL_REPORT.md", "research/phase3c/evidence.json"):
        assert (d1 / rel).read_text() == (d2 / rel).read_text(), rel
