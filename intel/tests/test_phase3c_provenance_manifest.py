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
    phase3c_manifest_integrity.snapshot(str(d))
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
    phase3c_manifest_integrity.snapshot(str(d))
    provenance.seal(str(d))

    manifest = d / "manifest.jsonl"
    lines = manifest.read_text(encoding="utf-8").splitlines()
    last = json.loads(lines[-1])
    last["seq"] = len(lines) + 1
    manifest.write_text(manifest.read_text(encoding="utf-8") + json.dumps(last, sort_keys=True) + "\n", encoding="utf-8")

    with pytest.raises(ValueError, match="manifest changed between acquisition snapshot and canonical sealing"):
        phase3c_manifest_integrity.seal(str(d))


def test_same_count_manifest_mutation_before_integrity_seal_is_refused(tmp_path, monkeypatch):
    run3(tmp_path / "d")
    monkeypatch.setenv("GITHUB_RUN_ID", "phase3c-test")
    monkeypatch.setenv("GITHUB_SHA", "test")
    d = tmp_path / "d"
    phase3c_manifest_integrity.snapshot(str(d))
    provenance.seal(str(d))

    manifest = d / "manifest.jsonl"
    entries = [json.loads(line) for line in manifest.read_text(encoding="utf-8").splitlines() if line.strip()]
    entries[0]["status"] = 201  # same entry count, but a changed raw-manifest byte sequence
    manifest.write_text("".join(json.dumps(entry, sort_keys=True) + "\n" for entry in entries), encoding="utf-8")

    with pytest.raises(ValueError, match="manifest changed between acquisition snapshot and canonical sealing"):
        phase3c_manifest_integrity.seal(str(d))


def test_manifest_drift_against_completed_runner_count_fails_before_normalization(tmp_path, monkeypatch):
    run3(tmp_path / "d")
    d = tmp_path / "d"
    manifest = d / "manifest.jsonl"
    lines = manifest.read_text(encoding="utf-8").splitlines()
    last = json.loads(lines[-1])
    last["seq"] = len(lines) + 1
    manifest.write_text(
        manifest.read_text(encoding="utf-8") + json.dumps(last, sort_keys=True) + "\\n",
        encoding="utf-8",
    )

    with pytest.raises(ValueError, match="manifest exchange count differs from completed acquisition metadata"):
        phase3c_manifest_integrity.snapshot(str(d))
    assert not (d / phase3c_manifest_integrity.SNAPSHOT_FILE).exists()
    assert not (d / "canonical" / "phase2_records.jsonl.gz").exists()
