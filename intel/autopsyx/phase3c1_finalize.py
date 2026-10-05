"""Phase 3C.1 evidence finalization.

Runs the frozen Phase 3C pipeline twice from the committed repository state,
checks that both reconstructions are byte-identical at the evidence-object
level, renders the reports, and refuses to promote the result to production.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import shutil
import subprocess
import tempfile
from pathlib import Path

from .research import phase3c_data as data
from .research import phase3c_pipeline as pipeline
from .research import phase3c_render as render

ROOT = Path(__file__).resolve().parents[1]


def _stable_hash(obj: dict) -> str:
    body = json.dumps(obj, sort_keys=True, default=str, separators=(",", ":")).encode()
    return hashlib.sha256(body).hexdigest()


def run() -> dict:
    included, excluded = data.eligible_archives()
    if not included:
        raise RuntimeError("no eligible Phase 3C archives are available")
    if excluded:
        # Exclusion is valid evidence, but a newly acquired archive with failed
        # provenance/completion must not silently disappear.
        bad = ", ".join(x["archive"] for x in excluded)
        raise RuntimeError(f"new Phase 3C archive failed eligibility: {bad}")

    with tempfile.TemporaryDirectory(prefix="autopsyx_p3c1_a_") as a, tempfile.TemporaryDirectory(prefix="autopsyx_p3c1_b_") as b:
        out_a = pipeline.run(Path(a))
        out_b = pipeline.run(Path(b))
        hash_a = _stable_hash(out_a)
        hash_b = _stable_hash(out_b)
        if hash_a != hash_b:
            raise RuntimeError(f"Phase 3C.1 deterministic replication failed: {hash_a} != {hash_b}")
        out = out_a
        out["phase3c1_verification"] = {
            "determinism": "PASS",
            "evidence_hash": hash_a,
            "independent_reconstruction_hash": hash_b,
            "independent_reconstruction_match": True,
            "eligible_archive_count": len(included),
            "new_archive_count": len(data.new_archives()),
            "production_integration": "NOT ATTEMPTED",
            "phase3d": "NOT STARTED",
        }
        render.write_all(out, ROOT)
    return out


def main() -> int:
    ap = argparse.ArgumentParser(prog="autopsyx.phase3c1_finalize")
    ap.parse_args()
    out = run()
    print(json.dumps({
        "overall": out["overall_classification"]["result"],
        "hypotheses": out["overall_classification"]["by_classification"],
        "archives": out["included_archives"],
        "evidence_hash": out["phase3c1_verification"]["evidence_hash"],
    }, indent=2, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
