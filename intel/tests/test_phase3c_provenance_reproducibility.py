"""Phase 3C regression checks for deterministic provenance sealing."""
import pytest

from autopsyx.data import provenance
from test_phase3a_universe import run3


def test_seal_refuses_nondeterministic_rebuild(tmp_path, monkeypatch):
    d = tmp_path / "d"
    run3(d)
    original_build = provenance.build
    calls = 0

    def unstable_build(run_dir):
        nonlocal calls
        calls += 1
        result = original_build(run_dir)
        if calls == 2:
            result = dict(result)
            result["phase2_records_sha256"] = "f" * 64
        return result

    monkeypatch.setattr(provenance, "build", unstable_build)
    with pytest.raises(ValueError, match="refusing to seal a non-reproducible archive"):
        provenance.seal(str(d))


def test_record_diff_identifies_first_changed_field(tmp_path):
    from dataclasses import replace

    d = tmp_path / "d"
    run3(d)
    records, _ = provenance.normalize(str(d))
    assert records
    changed = list(records)
    changed[0] = replace(records[0], seen_ts=records[0].seen_ts + 1)
    diff = provenance._record_diff(records, changed)
    assert diff["index"] == 0
    assert diff["left_type"] == type(records[0]).__name__
    assert "seen_ts" in diff["changed_fields"]
