"""Fail-closed reproducibility check for the immutable Phase 3C archive.

The test proves three distinct properties:
1. the archive's normalizer version matches the acquisition-runner version;
2. current normalization reproduces the runner hash and committed canonical records;
3. independent Python processes with different hash seeds reproduce the same records.

A missing archive or runner hash is a failure, not a skip. This test does not certify
statistical readiness or change any frozen acquisition threshold.
"""
from __future__ import annotations

import gzip
import json
import os
import subprocess
import sys
from dataclasses import asdict
from pathlib import Path

from autopsyx.data import provenance
from autopsyx.providers.store import _encode, decode_record

ROOT = Path(__file__).resolve().parents[1]
ARCHIVE = ROOT / "datasets" / "phase3c" / "runs" / "p3c-sol-20261020a"


def _record_dict(record):
    return _encode(asdict(record))


def _first_difference(left, right):
    for i, (a, b) in enumerate(zip(left, right)):
        da, db = _record_dict(a), _record_dict(b)
        if da != db:
            fields = sorted(k for k in set(da) | set(db) if da.get(k) != db.get(k))
            return {
                "index": i,
                "left_type": type(a).__name__,
                "right_type": type(b).__name__,
                "left_raw_id": getattr(a, "raw_id", None),
                "right_raw_id": getattr(b, "raw_id", None),
                "different_fields": fields,
                "left_record": da,
                "right_record": db,
            }
    if len(left) != len(right):
        i = min(len(left), len(right))
        return {
            "index": i,
            "left_length": len(left),
            "right_length": len(right),
            "left_type": type(left[i]).__name__ if i < len(left) else None,
            "right_type": type(right[i]).__name__ if i < len(right) else None,
        }
    return None


def _first_dict_difference(left, right):
    for i, (a, b) in enumerate(zip(left, right)):
        if a != b:
            fields = sorted(k for k in set(a) | set(b) if a.get(k) != b.get(k))
            return {"index": i, "different_fields": fields, "left_record": a, "right_record": b}
    if len(left) != len(right):
        return {"index": min(len(left), len(right)), "left_length": len(left), "right_length": len(right)}
    return None


def _runner_provenance():
    run_path = ARCHIVE / "run.json"
    assert run_path.is_file(), f"immutable archive metadata missing: {run_path}"
    metadata = json.loads(run_path.read_text(encoding="utf-8"))
    recorded = metadata.get("provenance")
    assert isinstance(recorded, dict), "archive has no acquisition-runner provenance block"
    runner_hash = recorded.get("runner_dataset_hash", {}).get("phase2_records")
    assert runner_hash, "archive has no runner-recorded Phase 2 hash"
    return metadata, recorded, runner_hash


def _load_committed_records():
    path = ARCHIVE / "canonical" / "phase2_records.jsonl.gz"
    assert path.is_file(), f"runner-sealed canonical records missing: {path}"
    with gzip.open(path, "rt", encoding="utf-8") as stream:
        return [decode_record(json.loads(line)) for line in stream if line.strip()]


def test_current_phase3c_archive_reproduces_runner_hash_and_canonical_records(tmp_path):
    assert (ARCHIVE / "manifest.jsonl").is_file(), (
        f"required immutable Phase 3C archive is missing: {ARCHIVE}; refusing to skip"
    )
    metadata, recorded, runner_hash = _runner_provenance()

    current_version = provenance.normalization_version()
    runner_version = recorded.get("normalization_version", {})
    assert current_version.get("sha256") == runner_version.get("sha256"), json.dumps(
        {
            "archive": ARCHIVE.name,
            "failure": "normalization source version differs from acquisition runner",
            "runner_version": runner_version.get("sha256"),
            "current_version": current_version.get("sha256"),
            "runner_sources": runner_version.get("sources"),
            "current_sources": current_version.get("sources"),
        },
        sort_keys=True,
    )

    rebuilt = provenance.build(str(ARCHIVE))
    committed = _load_committed_records()
    committed_hash = provenance.records_sha256(committed)
    difference = _first_difference(committed, rebuilt["records"])
    assert (
        rebuilt["phase2_records_sha256"] == runner_hash
        and committed_hash == runner_hash
        and difference is None
    ), json.dumps(
        {
            "archive": ARCHIVE.name,
            "runner_hash": runner_hash,
            "committed_canonical_hash": committed_hash,
            "rebuilt_hash": rebuilt["phase2_records_sha256"],
            "runner_status": metadata.get("status"),
            "runner_commit": recorded.get("repository_commit"),
            "runner_python": recorded.get("environment", {}).get("python"),
            "current_python": sys.version.split()[0],
            "runner_record_count": len(committed),
            "rebuilt_record_count": len(rebuilt["records"]),
            "first_difference": difference,
            "rebuilt_tail_after_runner_canonical": [
                _record_dict(record) for record in rebuilt["records"][len(committed):len(committed) + 12]
            ],
            "runner_canonical_tail": [
                _record_dict(record) for record in committed[-3:]
            ],
            "manifest_entries": len(provenance.RawStore(ARCHIVE).entries()) if hasattr(provenance, "RawStore") else None,
        },
        sort_keys=True,
    )

    # Rebuild in independent interpreters: an in-process double call cannot
    # detect all PYTHONHASHSEED-dependent iteration-order defects.
    script = (
        "import json,sys; from dataclasses import asdict; "
        "from autopsyx.data import provenance as p; "
        "from autopsyx.providers.store import _encode; "
        "b=p.build(sys.argv[1]); "
        "json.dump({'hash':b['phase2_records_sha256'],"
        "'records':[_encode(asdict(r)) for r in b['records']]},"
        "open(sys.argv[2],'w',encoding='utf-8'),sort_keys=True,default=str)"
    )
    process_results = []
    for seed in ("0", "1"):
        output = tmp_path / f"phase2-seed-{seed}.json"
        env = dict(os.environ, PYTHONHASHSEED=seed)
        proc = subprocess.run(
            [sys.executable, "-c", script, str(ARCHIVE), str(output)],
            cwd=ROOT,
            env=env,
            capture_output=True,
            text=True,
            timeout=180,
        )
        assert proc.returncode == 0, json.dumps(
            {"seed": seed, "returncode": proc.returncode, "stdout": proc.stdout[-4000:],
             "stderr": proc.stderr[-4000:]},
            sort_keys=True,
        )
        process_results.append(json.loads(output.read_text(encoding="utf-8")))

    cross_difference = _first_dict_difference(
        process_results[0]["records"], process_results[1]["records"]
    )
    assert (
        process_results[0]["hash"] == runner_hash
        and process_results[1]["hash"] == runner_hash
        and cross_difference is None
    ), json.dumps(
        {
            "archive": ARCHIVE.name,
            "runner_hash": runner_hash,
            "seed_0_hash": process_results[0]["hash"],
            "seed_1_hash": process_results[1]["hash"],
            "first_cross_process_difference": cross_difference,
        },
        sort_keys=True,
    )
