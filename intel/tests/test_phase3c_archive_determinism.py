"""Regression test documenting and detecting the immutable Phase 3C archive drift.

The old archive must remain rejected; do not rewrite it to make its hash pass.
Removing only the final manifest entry must reproduce the runner's hash exactly.
"""
from __future__ import annotations

import gzip
import json
from pathlib import Path

from autopsyx.data import provenance
from autopsyx.data.normalize import normalize
from autopsyx.research import phase3c_manifest_integrity
from autopsyx.providers.store import decode_record

ROOT = Path(__file__).resolve().parents[1]
ARCHIVE = ROOT / "datasets" / "phase3c" / "runs" / "p3c-sol-20261020a"


def _load_committed_records():
    path = ARCHIVE / "canonical" / "phase2_records.jsonl.gz"
    assert path.is_file(), f"runner-sealed canonical records missing: {path}"
    with gzip.open(path, "rt", encoding="utf-8") as stream:
        return [decode_record(json.loads(line)) for line in stream if line.strip()]


def test_immutable_phase3c_archive_is_rejected_for_manifest_drift(tmp_path):
    assert (ARCHIVE / "manifest.jsonl").is_file(), (
        f"required immutable Phase 3C archive is missing: {ARCHIVE}; refusing to skip"
    )
    metadata = json.loads((ARCHIVE / "run.json").read_text(encoding="utf-8"))
    recorded = metadata.get("provenance")
    assert isinstance(recorded, dict), "archive has no acquisition-runner provenance"
    runner_hash = recorded["runner_dataset_hash"]["phase2_records"]
    runner_count = recorded["record_counts"]["manifest_exchanges"]
    runner_counts = recorded["record_counts"]["phase2_records"]
    lines = (ARCHIVE / "manifest.jsonl").read_text(encoding="utf-8").splitlines()
    entries = [json.loads(line) for line in lines if line.strip()]
    assert runner_count == 925
    assert len(entries) == 926
    assert entries[-1]["seq"] == 926 and entries[-1]["endpoint"] == "gt.ohlcv"

    manifest_verification = phase3c_manifest_integrity.verify(str(ARCHIVE))
    committed = _load_committed_records()
    rebuilt_records, _ = normalize(str(ARCHIVE))
    rebuilt_hash = provenance.records_sha256(rebuilt_records)
    rebuilt_counts = {}
    for record in rebuilt_records:
        kind = type(record).__name__
        rebuilt_counts[kind] = rebuilt_counts.get(kind, 0) + 1

    # The immutable runner metadata records 925 exchanges, but the current
    # manifest has 926. The final OHLCV response contributes exactly six bars.
    assert manifest_verification["verified"] is False
    assert manifest_verification["reason"] == "manifest_seal_missing"
    assert manifest_verification["manifest_count_matches_runner"] is False
    assert manifest_verification["manifest_exchanges_runner"] == 925
    assert manifest_verification["manifest_exchanges_current"] == 926
    assert len(committed) == 49_356
    assert len(rebuilt_records) == 49_362
    assert len(rebuilt_records) - len(committed) == 6
    assert runner_counts["ProviderBar"] == 9_975
    assert rebuilt_counts["ProviderBar"] == 9_981
    assert all(
        rebuilt_counts.get(kind, 0) - runner_counts.get(kind, 0) == (6 if kind == "ProviderBar" else 0)
        for kind in set(runner_counts) | set(rebuilt_counts)
    )
    assert provenance.records_sha256(committed) == runner_hash
    assert rebuilt_hash != runner_hash
    assert recorded["normalization_version"]["sha256"] == provenance.normalization_version()["sha256"]

    # Root-cause proof: using only the 925-entry manifest snapshot reproduces
    # the runner's hash; the content-addressed raw bodies remain untouched.
    prefix = tmp_path / "manifest-prefix"
    prefix.mkdir()
    (prefix / "manifest.jsonl").write_text("\n".join(lines[:-1]) + "\n", encoding="utf-8")
    (prefix / "raw").symlink_to(ARCHIVE / "raw", target_is_directory=True)
    prefix_records, _ = normalize(str(prefix))
    assert len(prefix_records) == len(committed)
    assert provenance.records_sha256(prefix_records) == runner_hash
