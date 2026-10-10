"""The committed Phase 2 evidence is internally consistent and the documents derive from it alone."""
import json
from pathlib import Path

import pytest

from autopsyx.data.normalize import normalize
from autopsyx.research import phase2_verify, trace_check

ROOT = Path(__file__).resolve().parents[2]
EV = ROOT / "artifacts" / "phase2" / "PHASE2_EVIDENCE.json"
REPORT = ROOT / "docs" / "PHASE2_REPORT.md"
# Frozen Phase 2 status. docs/SYSTEM_STATUS.md is now the living Phase 3A status.
STATUS = ROOT / "docs" / "PHASE2_SYSTEM_STATUS.md"

needs_evidence = pytest.mark.skipif(not EV.exists(), reason="Phase 2 evidence not generated yet")


@pytest.fixture(scope="module")
def ev():
    return json.loads(EV.read_text())


@needs_evidence
def test_documents_are_exact_renderings_of_the_evidence(ev):
    assert REPORT.read_text() == phase2_verify.render(ev)
    assert STATUS.read_text() == phase2_verify.render_status(ev)


@needs_evidence
def test_every_number_in_the_documents_traces_to_the_evidence():
    for doc in (REPORT, STATUS):
        assert trace_check.check_files(str(doc), str(EV)) == [], doc.name


@needs_evidence
def test_stored_classification_is_what_the_rule_produces(ev):
    c, why, inputs = phase2_verify.classify(ev)
    assert (c, why) == (ev["classification"]["result"], ev["classification"]["reasons"])
    assert inputs == ev["classification"]["inputs"]
    assert ev["classification"]["rule"] == phase2_verify.CLASSIFICATION_RULE


@needs_evidence
def test_every_archive_in_the_evidence_reproduces_from_its_raw_data(ev):
    for r in ev["runs"]:
        run_dir = ROOT / "intel" / "datasets" / "phase2" / "runs" / r["run_id"]
        assert run_dir.exists(), r["run_id"]
        assert normalize(str(run_dir))[1].dataset_sha256 == r["dataset_sha256_local"]


@needs_evidence
def test_scope_audit_clean(ev):
    sc = ev["scope"]
    assert sc["engine_changes_unexplained"] == {}  # every engine edit is listed, line for line, with its reason
    assert set(sc["engine_changed_lines"]) <= set(phase2_verify.ENGINE_CHANGES_EXPLAINED)
    assert sc["config_lines_removed"] == []
    assert sc["forbidden_terms_present"] == {}


def test_scope_audit_does_not_flag_itself():
    """The audit defines the forbidden-term list; scanning must exclude that file and still catch others."""
    sc = phase2_verify.scope_audit("e8c4f66")
    assert sc["forbidden_terms_present"] == {}
    assert sc["engine_changes_unexplained"] == {}
    assert "place_order" in (Path(phase2_verify.__file__).read_text())  # the list really is in this file


def test_rule_fingerprint_detects_rule_changes():
    src = Path(phase2_verify.__file__).read_text()
    base = phase2_verify.rule_fingerprint(src)
    assert phase2_verify.rule_fingerprint(src.replace("\nREQUIRED_OK_SHARE = 0.5", "\nREQUIRED_OK_SHARE = 0.4")) != base
    assert phase2_verify.rule_fingerprint(src.replace("if pa[\"classified_assessments\"] == 0:",
                                                      "if pa[\"classified_assessments\"] < 0:")) != base
    # unrelated renderer text does not change it
    assert phase2_verify.rule_fingerprint(src.replace("## Archive Comparison", "## Archives")) == base


def test_rule_in_force_equals_rule_frozen_before_newest_archive():
    f = phase2_verify.rule_freeze(ROOT / "intel" / "datasets" / "phase2" / "runs")
    assert f["identical_to_frozen"], f
