"""Runner canonical-dataset sealing and its verification."""
import gzip
import json
import os
import subprocess
import sys
from pathlib import Path

from autopsyx.data import provenance as pv

from test_phase3a_universe import run3

ROOT = Path(__file__).resolve().parents[1]


def sealed(tmp_path, monkeypatch):
    run3(tmp_path / "d")
    monkeypatch.setenv("GITHUB_RUN_ID", "123")
    monkeypatch.setenv("GITHUB_SHA", "abc")
    pv.seal(str(tmp_path / "d"))
    return tmp_path / "d"


def test_seal_records_required_metadata(tmp_path, monkeypatch):
    d = sealed(tmp_path, monkeypatch)
    p = json.loads((d / "run.json").read_text())["provenance"]
    for k in ("run_id", "workflow_run_id", "started_at", "completed_at", "providers", "endpoints",
              "canonical_dataset_version", "normalization_version", "config_hash", "dataset_hash_algorithm",
              "runner_dataset_hash", "record_counts", "coverage_summary", "repository_commit", "environment"):
        assert k in p, k
    assert p["workflow_run_id"] == "123" and p["repository_commit"] == "abc"
    assert (d / "canonical" / "phase2_records.jsonl.gz").exists()
    assert json.loads((d / "normalize_stdout.json").read_text())["dataset_sha256"] == p["runner_dataset_hash"]["phase2_records"]


def test_sealed_archive_verifies(tmp_path, monkeypatch):
    v = pv.verify(str(sealed(tmp_path, monkeypatch)))
    assert v["verified"] and v["reproducible"] and v["committed_matches_runner"] and v["rebuild_matches_runner"]
    assert v["normalization_version_match"] and v["config_hash_runner"] == v["config_hash_local"]


def test_canonical_files_are_byte_stable(tmp_path, monkeypatch):
    d = sealed(tmp_path, monkeypatch)
    first = {f.name: f.read_bytes() for f in (d / "canonical").iterdir()}
    pv.seal(str(d))
    assert {f.name: f.read_bytes() for f in (d / "canonical").iterdir()} == first


def test_tampered_canonical_file_fails(tmp_path, monkeypatch):
    d = sealed(tmp_path, monkeypatch)
    f = d / "canonical" / "phase3a_observations.jsonl.gz"
    lines = gzip.decompress(f.read_bytes()).decode().splitlines()
    f.write_bytes(gzip.compress(("\n".join(lines[:-1]) + "\n").encode(), mtime=0))  # one record missing
    v = pv.verify(str(d))
    assert not v["verified"] and v["committed_matches_runner"] is False and v["rebuild_matches_runner"]


def test_wrong_runner_hash_fails(tmp_path, monkeypatch):
    d = sealed(tmp_path, monkeypatch)
    m = json.loads((d / "run.json").read_text())
    m["provenance"]["runner_dataset_hash"]["phase2_records"] = "0" * 64
    (d / "run.json").write_text(json.dumps(m))
    assert not pv.verify(str(d))["verified"]


def test_tampered_raw_body_fails(tmp_path, monkeypatch):
    d = sealed(tmp_path, monkeypatch)
    e = next(x for x in pv.RawStore(d).entries() if x.endpoint == "gt.trades" and x.raw_id)
    body = gzip.decompress((d / "raw" / f"{e.raw_id}.json.gz").read_bytes())
    (d / "raw" / f"{e.raw_id}.json.gz").write_bytes(gzip.compress(body.replace(b'"buy"', b'"sell"', 1), mtime=0))
    try:
        v = pv.verify(str(d))
        assert not v["verified"]
    except ValueError as exc:  # the raw store refuses a body that fails its own hash
        assert "fails its own hash" in str(exc)


def test_unsealed_archive_is_not_verified(tmp_path):
    run3(tmp_path / "d")
    v = pv.verify(str(tmp_path / "d"))
    assert v["verified"] is False and v["source"] == "none"


def test_incomplete_acquisition_is_not_verified(tmp_path, monkeypatch):
    d = sealed(tmp_path, monkeypatch)
    m = json.loads((d / "run.json").read_text())
    m["status"] = "BLOCKED: no pools selectable (discovery failed)"
    (d / "run.json").write_text(json.dumps(m))
    assert not pv.verify(str(d))["verified"]


def test_phase2_archive_verifies_against_its_runner_hash():
    v = pv.verify(str(ROOT / "datasets" / "phase2" / "runs" / "gt-sol-20260930c"))
    assert v["verified"] and v["scope"].startswith("phase2_records only")


def test_hash_independent_of_process_hash_seed(tmp_path, monkeypatch):
    d = sealed(tmp_path, monkeypatch)
    code = "import sys,json;sys.path.insert(0,'.');from autopsyx.data import provenance as p;b=p.build(sys.argv[1]);" \
           "print(b['phase2_records_sha256'],b['phase3a_observations_sha256'])"
    outs = {subprocess.run([sys.executable, "-c", code, str(d)], cwd=ROOT, capture_output=True, text=True,
                           env=dict(os.environ, PYTHONHASHSEED=s)).stdout for s in ("0", "1")}
    assert len(outs) == 1 and outs.pop().strip()
