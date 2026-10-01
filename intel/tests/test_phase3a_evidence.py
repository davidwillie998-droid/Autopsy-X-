"""The committed Phase 3A evidence is internally consistent and the documents derive from it alone."""
import hashlib
import json
from pathlib import Path

import pytest

from autopsyx.data.normalize3a import normalize_phase3a, observations_sha256
from autopsyx.research import phase3a_coverage as cov
from autopsyx.research import phase3a_readiness as rd
from autopsyx.research import phase3a_verify as v
from autopsyx.research import trace_check

ROOT = Path(__file__).resolve().parents[2]
EV = ROOT / "artifacts" / "phase3a" / "PHASE3A_EVIDENCE.json"
COV = ROOT / "artifacts" / "phase3a" / "PHASE3A_COVERAGE.json"
REPORT = ROOT / "docs" / "PHASE3A_REPORT.md"
STATUS = ROOT / "docs" / "SYSTEM_STATUS.md"

needs_evidence = pytest.mark.skipif(not EV.exists(), reason="Phase 3A evidence not generated yet")


@pytest.fixture(scope="module")
def ev():
    return json.loads(EV.read_text())


@needs_evidence
def test_documents_are_exact_renderings_of_the_evidence(ev):
    assert REPORT.read_text() == v.render(ev)
    assert STATUS.read_text() == v.render_status(ev)


@needs_evidence
def test_every_number_in_the_documents_traces_to_the_evidence(ev):
    src = Path(v.__file__).read_text()
    for doc in (REPORT, STATUS):
        assert trace_check.check(doc.read_text(), ev, src) == [], doc.name


@needs_evidence
def test_coverage_file_matches_evidence(ev):
    m = json.loads(COV.read_text())
    assert hashlib.sha256(json.dumps(m, sort_keys=True).encode()).hexdigest() == ev["coverage"]["sha256"]
    assert m["blank_cells"] == 0 and m["totals"] == ev["coverage"]["totals"]
    assert m["dimensions"] == list(cov.DIMENSIONS)


@needs_evidence
def test_readiness_is_what_the_gate_produces(ev):
    assert v._readiness(ev) == ev["readiness"]
    assert ev["readiness"]["config"] == rd.load_config()


@needs_evidence
def test_every_archive_reproduces_its_observations(ev):
    for r in ev["archives"]:
        d = next(p for base in v.ARCHIVE_DIRS for p in [base / r["archive"]] if p.exists())
        assert observations_sha256(normalize_phase3a(str(d))[0]) == r["replay"]["observations_sha256"][0]


@needs_evidence
def test_evidence_covers_every_archive_on_disk(ev):
    assert sorted(r["archive"] for r in ev["archives"]) == sorted(p.name for p in v.archives())


@needs_evidence
def test_integrity_and_scope(ev):
    assert all(ev["integrity"].values()), ev["integrity"]
    assert ev["scope"]["hypotheses"]["tested_in_phase3a"] == []
    assert set(ev["scope"]["existing_tests_changed"]) <= set(v.TEST_CHANGES_EXPLAINED)
    assert not ev["repository"]["code_version"].endswith("-dirty")


def test_renderer_never_counts():
    """Aggregates come from the evidence; the renderer may format, not compute."""
    src = Path(v.__file__).read_text()
    body = src[src.index("# ----------------------------------------------------------------- render ----"):]
    for banned in ("len(", "sum(", "Counter(", "max(", "min(", "round("):
        assert banned not in body, banned
