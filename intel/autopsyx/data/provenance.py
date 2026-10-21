"""Canonical dataset sealing and verification for an acquisition run.

The canonical dataset of a run is what downstream research consumes:

  phase2_records       output of ``data.normalize.normalize`` (the Phase 2
                       normalizer, unchanged), in normalizer order
  phase3a_observations output of ``data.normalize3a.normalize_phase3a``, in
                       its deduplicated canonical order

Hash algorithm (``HASH_ALGORITHM``), identical to the one the Phase 2 and
Phase 3A normalizers already report, so no new algorithm is introduced:

  phase2_records       sha256 over the concatenation, in record order, of
                       UTF-8 json.dumps(record_dict, sort_keys=True,
                       default=str) with enums as their values and tuples as
                       lists; no separator between records
  phase3a_observations sha256 over UTF-8 json.dumps(observation.to_dict(),
                       sort_keys=True) + "\\n" per observation, in order

Numbers are serialized by Python's json (shortest round-trip repr), nulls as
``null``, timestamps as integer milliseconds, keys sorted at every level.

``seal`` runs on the acquisition runner: it normalizes, writes the canonical
files (gzip, mtime 0) under ``canonical/``, ``normalize_stdout.json`` (Phase 2
parity) and a ``provenance`` block in ``run.json``. ``verify`` runs anywhere:
it rebuilds the dataset from the committed raw archive twice, decodes the
committed canonical files, and compares all hashes with the runner's.
"""
from __future__ import annotations

import gzip
import hashlib
import json
import os
import platform
import sys
from dataclasses import asdict
from datetime import datetime, timezone
from pathlib import Path

from ..core.config import Config
from ..core.observation import SCHEMA_VERSION, Observation
from ..providers.store import EventStore, _encode, decode_record
from .normalize import normalize
from .normalize3a import normalize_phase3a, observations_sha256
from .raw import RawStore

CANONICAL_DATASET_VERSION = "3a.1"
HASH_ALGORITHM = ("sha256; phase2_records: concat of json.dumps(record, sort_keys=True, default=str) in normalizer "
                  "order; phase3a_observations: json.dumps(observation.to_dict(), sort_keys=True) + newline in "
                  "canonical order")
PKG = Path(__file__).resolve().parents[1]
# Every source file whose behaviour determines the canonical dataset.
NORMALIZATION_SOURCES = sorted([
    "data/normalize.py", "data/normalize3a.py", "data/raw.py", "data/validate.py",
    "data/providers/geckoterminal.py", "data/providers/dexscreener.py", "data/providers/gt_phase3a.py",
    "data/providers/solana_rpc.py", "data/providers/news_social.py",
    "core/models.py", "core/observation.py", "providers/store.py", "pipeline.py",
])


def normalization_version() -> dict:
    files = {f: hashlib.sha256((PKG / f).read_bytes()).hexdigest() for f in NORMALIZATION_SOURCES}
    return {"sources": files, "sha256": hashlib.sha256(json.dumps(files, sort_keys=True).encode()).hexdigest(),
            "observation_schema": SCHEMA_VERSION}


def records_sha256(records: list) -> str:
    h = hashlib.sha256()
    for r in records:
        h.update(json.dumps(_encode(asdict(r)), sort_keys=True, default=str).encode())
    return h.hexdigest()


def build(run_dir: str) -> dict:
    """Rebuild the canonical dataset from the raw archive."""
    records, rep = normalize(run_dir)
    obs, issues = normalize_phase3a(run_dir)
    p2 = records_sha256(records)
    assert p2 == rep.dataset_sha256  # same algorithm the Phase 2 normalizer reports
    return {"records": records, "observations": obs, "report": rep, "issues": issues,
            "phase2_records_sha256": p2, "phase3a_observations_sha256": observations_sha256(obs)}


def _iso(ms):
    return datetime.fromtimestamp(ms / 1000, tz=timezone.utc).isoformat() if isinstance(ms, int) else None


def seal(run_dir: str) -> dict:
    d = Path(run_dir)
    raw = RawStore(d)
    b = build(run_dir)
    (d / "canonical").mkdir(exist_ok=True)
    tmp = d / "canonical" / "phase2_records.jsonl"
    EventStore.dump_jsonl(tmp, b["records"])
    (d / "canonical" / "phase2_records.jsonl.gz").write_bytes(gzip.compress(tmp.read_bytes(), mtime=0))
    tmp.unlink()
    obs_lines = "".join(json.dumps(o.to_dict(), sort_keys=True) + "\n" for o in b["observations"]).encode()
    (d / "canonical" / "phase3a_observations.jsonl.gz").write_bytes(gzip.compress(obs_lines, mtime=0))
    rep = b["report"]
    raw.write_json("normalize_stdout.json", {"records": rep.records, "issues": rep.issues,
                                             "dataset_sha256": rep.dataset_sha256})
    meta = raw.read_json("run.json") or {}
    entries = raw.entries()
    from collections import Counter
    env = {"python": sys.version.split()[0], "platform": platform.platform(),
           "runner_name": os.environ.get("RUNNER_NAME"), "runner_os": os.environ.get("RUNNER_OS"),
           "github_workflow": os.environ.get("GITHUB_WORKFLOW"), "github_repository": os.environ.get("GITHUB_REPOSITORY")}
    meta["provenance"] = {
        "run_id": d.name,
        "workflow_run_id": os.environ.get("GITHUB_RUN_ID"),
        "workflow_run_attempt": os.environ.get("GITHUB_RUN_ATTEMPT"),
        "repository_commit": os.environ.get("GITHUB_SHA"),
        "started_at": _iso(meta.get("started_ms")), "completed_at": _iso(meta.get("ended_ms")),
        "acquisition_status": meta.get("status"),
        "providers": sorted({e.provider for e in entries if e.provider != "audit"}),
        "endpoints": dict(sorted(Counter(e.endpoint for e in entries).items())),
        "canonical_dataset_version": CANONICAL_DATASET_VERSION,
        "normalization_version": normalization_version(),
        "config_hash": Config.load().fingerprint(),
        "dataset_hash_algorithm": HASH_ALGORITHM,
        "runner_dataset_hash": {"phase2_records": b["phase2_records_sha256"],
                                "phase3a_observations": b["phase3a_observations_sha256"]},
        "canonical_files": {"phase2_records": "canonical/phase2_records.jsonl.gz",
                            "phase3a_observations": "canonical/phase3a_observations.jsonl.gz"},
        "record_counts": {"phase2_records": rep.records, "phase3a_observations": len(b["observations"]),
                          "manifest_exchanges": len(entries), "manifest_errors": sum(1 for e in entries if e.error)},
        "coverage_summary": {"phase3a_by_kind_state": dict(sorted(Counter(f"{o.kind}|{o.state.value}"
                                                                          for o in b["observations"]).items())),
                             "phase2_tokens": rep.tokens, "phase2_issues": rep.issues},
        "environment": {k: v for k, v in env.items()},
        "unavailable_fields": sorted(k for k, v in env.items() if v is None),
    }
    raw.write_json("run.json", meta)
    return meta["provenance"]


def _read_committed(d: Path) -> tuple[str | None, str | None]:
    p2 = d / "canonical" / "phase2_records.jsonl.gz"
    p3 = d / "canonical" / "phase3a_observations.jsonl.gz"
    h2 = h3 = None
    if p2.exists():
        recs = [decode_record(json.loads(l)) for l in gzip.decompress(p2.read_bytes()).decode().splitlines() if l.strip()]
        h2 = records_sha256(recs)
    if p3.exists():
        obs = [Observation.from_dict(json.loads(l)) for l in gzip.decompress(p3.read_bytes()).decode().splitlines()
               if l.strip()]
        h3 = observations_sha256(obs)
    return h2, h3


def verify(run_dir: str) -> dict:
    """Provenance chain check for one archive. ``verified`` requires exact
    equality of every hash with the runner's; nothing else substitutes."""
    d = Path(run_dir)
    raw = RawStore(d)
    meta = raw.read_json("run.json") or {}
    prov = meta.get("provenance")
    legacy = raw.read_json("normalize_stdout.json")  # Phase 2 runner output
    r1, r2 = build(run_dir), build(run_dir)
    c2, c3 = _read_committed(d)
    out = {"archive": d.name, "acquisition_status": meta.get("status"),
           "rebuild_1": {"phase2_records": r1["phase2_records_sha256"], "phase3a_observations": r1["phase3a_observations_sha256"]},
           "rebuild_2": {"phase2_records": r2["phase2_records_sha256"], "phase3a_observations": r2["phase3a_observations_sha256"]},
           "committed_canonical": {"phase2_records": c2, "phase3a_observations": c3}}
    out["reproducible"] = out["rebuild_1"] == out["rebuild_2"]
    if prov:
        rh = prov["runner_dataset_hash"]
        out["source"] = "run.json provenance (sealed on runner)"
        out["runner"] = rh
        out["workflow_run_id"] = prov.get("workflow_run_id")
        out["config_hash_runner"] = prov.get("config_hash")
        out["config_hash_local"] = Config.load().fingerprint()
        out["normalization_version_match"] = prov["normalization_version"]["sha256"] == normalization_version()["sha256"]
        out["committed_matches_runner"] = (c2, c3) == (rh["phase2_records"], rh["phase3a_observations"])
        out["rebuild_matches_runner"] = out["rebuild_1"] == rh
        out["verified"] = bool(out["reproducible"] and out["committed_matches_runner"] and out["rebuild_matches_runner"]
                               and meta.get("status") == "COMPLETE")
        out["scope"] = "phase2_records and phase3a_observations"
    elif legacy:
        # Phase 2 archives: the runner hashed the Phase 2 records only; Phase 3A
        # observations did not exist then, so they are reproducibility-checked only.
        out["source"] = "normalize_stdout.json (Phase 2 runner normalization)"
        out["runner"] = {"phase2_records": legacy.get("dataset_sha256"), "phase3a_observations": None}
        out["rebuild_matches_runner"] = out["rebuild_1"]["phase2_records"] == legacy.get("dataset_sha256")
        out["committed_matches_runner"] = None
        out["verified"] = bool(out["reproducible"] and out["rebuild_matches_runner"])
        out["scope"] = "phase2_records only (archive predates Phase 3A runner sealing)"
    else:
        out["source"] = "none"
        out["verified"] = False
        out["scope"] = "no runner dataset hash recorded"
    return out
