"""Phase 3C-only raw-manifest integrity regression tests."""
import json

import pytest
from autopsyx.data import provenance
from autopsyx.research import phase3c_manifest_integrity

from test_phase3a_universe import run3


def test_manifest_mutation_after_seal_is_rejected(tmp_path, monkeypatch):
    run3(tmp_path / "d")
    monkeypatch.setenv("GITHUB_RUN_ID", "phase3c-test")
    monkeypatch.setenv("GITHUB_SHA", "test")
    d = tmp_path / "d"
    provenance.seal(str(d))
    phase3c_manifest_integrity.seal(str(d))

    manifest = d / "manifest.jsonl"
    manifest.write_text(manifest.read_text(encoding="utf-8") + "\n", encoding="utf-8")

    result = phase3c_manifest_integrity.verify(str(d))
    assert result["verified"] is False
    assert result["manifest_count_matches_runner"] is True
    assert result["manifest_hash_matches_seal"] is False
    assert result["manifest_count_matches_seal"] is True


def test_manifest_append_between_canonical_and_manifest_seal_is_refused(tmp_path, monkeypatch):
    from pathlib import Path

    run3(tmp_path / "d")
    monkeypatch.setenv("GITHUB_RUN_ID", "phase3c-test")
    monkeypatch.setenv("GITHUB_SHA", "test")
    d = tmp_path / "d"
    provenance.seal(str(d))

    manifest = d / "manifest.jsonl"
    lines = manifest.read_text(encoding="utf-8").splitlines()
    last = json.loads(lines[-1])
    last["seq"] = len(lines) + 1
    manifest.write_text(manifest.read_text(encoding="utf-8") + json.dumps(last, sort_keys=True) + "\n", encoding="utf-8")

    with pytest.raises(ValueError, match="manifest changed during canonical sealing"):
        phase3c_manifest_integrity.seal(str(d))
