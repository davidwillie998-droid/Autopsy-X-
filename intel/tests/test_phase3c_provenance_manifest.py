"""Phase 3C raw-manifest integrity regression tests."""
import json
from pathlib import Path

from autopsyx.data import provenance as pv

from test_phase3a_universe import run3


def test_manifest_mutation_after_seal_is_rejected(tmp_path, monkeypatch):
    run3(tmp_path / "d")
    monkeypatch.setenv("GITHUB_RUN_ID", "phase3c-test")
    monkeypatch.setenv("GITHUB_SHA", "test")
    d = tmp_path / "d"
    pv.seal(str(d))

    manifest = d / "manifest.jsonl"
    manifest.write_text(manifest.read_text(encoding="utf-8") + "\n", encoding="utf-8")

    result = pv.verify(str(d))
    assert result["reproducible"]
    assert result["rebuild_matches_runner"]
    assert result["committed_matches_runner"]
    assert result["manifest_count_matches_runner"] is True
    assert result["manifest_matches_runner"] is False
    assert result["verified"] is False
