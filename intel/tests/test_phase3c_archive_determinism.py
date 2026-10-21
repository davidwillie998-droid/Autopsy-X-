"""Regression test documenting and detecting the immutable Phase 3C archive drift.

The old archive must remain rejected; do not rewrite it to make its hash pass.
The test proves that the final manifest entry was appended after the canonical
snapshot: removing only that final entry reproduces the runner's hash exactly.
"""
from __future__ import annotations

import gzip
import json
import os
import subprocess
import sys
from pathlib import Path

from autopsyx.data import provenance
from autopsyx.data.normalize import normalize
from autopsyx.data.raw import RawStore
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
    lines = (ARCHIVE / "manifest.jsonl").read_text(encoding="utf-8").splitlines()
    entries = [json.loads(line) for line in lines if line.strip()]
    assert runner_count == 925
    assert len(entries) == 926
    assert entries[-1]["seq"] == 926 and entries[-1]["endpoint"] == "gt.ohlcv"

    verification = provenance.verify(str(ARCHIVE))
    entries = provenance.RawStore(ARCHIVE).entries()
    # The immutable runner metadata proves that exactly one raw exchange was
    # appended after canonical sealing: seq 926 is an OHLCV response that
    # yields six extra ProviderBar records.
    assert verification["manifest_exchanges_runner"] == 925
    assert verification["manifest_exchanges_current"] == 926
    assert verification["manifest_count_matches_runner"] is False
    assert entries[-1].seq == 926 and entries[-1].endpoint == "gt.ohlcv"
    assert len(rebuilt["records"]) - len(committed) == 6
    assert all(type(record).__name__ == "ProviderBar" for record in rebuilt["records"][len(committed):])
    assert verification["verified"] is False
    assert verification["manifest_matches_runner"] is False
    assert verification["manifest_count_matches_runner"] is False
    assert verification["manifest_exchanges_runner"] == 925
    assert verification["manifest_exchanges_current"] == 926
    assert verification["committed_matches_runner"] is True
    assert verification["rebuild_matches_runner"] is False
    assert verification["normalization_version_match"] is True

    committed = _load_committed_records()
    rebuilt_count = verification["rebuild_counts"]["phase2_records"]
    assert len(committed) == 49_356
    assert rebuilt_count == 49_362
    assert verification["rebuild_1"]["phase2_records"] != runner_hash
    assert provenance.records_sha256(committed) == runner_hash

    # Root-cause proof: use the exact manifest prefix recorded at seal time.
    # The raw bodies remain content-addressed and are not modified.
    prefix = tmp_path / "manifest-prefix"
    prefix.mkdir()
    (prefix / "manifest.jsonl").write_text("\\n".join(lines[:-1]) + "\\n", encoding="utf-8")
    (prefix / "raw").symlink_to(ARCHIVE / "raw", target_is_directory=True)
    prefix_records, _ = normalize(str(prefix))
    assert len(prefix_records) == len(committed)
    assert provenance.records_sha256(prefix_records) == runner_hash

    # Independently confirm that today's full-manifest rebuild is deterministic
    # across interpreter processes, even though it must not match the old seal.
    script = (
        "import sys; sys.path.insert(0,'.'); "
        "from autopsyx.data.provenance import build; "
        "print(build(sys.argv[1])['phase2_records_sha256'])"
    )
    hashes = []
    for seed in ("0", "1"):
        proc = subprocess.run(
            [sys.executable, "-c", script, str(ARCHIVE)],
            cwd=ROOT,
            env=dict(os.environ, PYTHONHASHSEED=seed),
            capture_output=True,
            text=True,
            timeout=180,
        )
        assert proc.returncode == 0, (
            f"seed={seed}, stdout={proc.stdout[-2000:]}, stderr={proc.stderr[-2000:]}"
        )
        hashes.append(proc.stdout.strip())
    assert hashes == [verification["rebuild_1"]["phase2_records"]] * 2
