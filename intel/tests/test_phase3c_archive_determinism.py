"""Regression diagnostic for Phase 3C canonical Phase 2 archive determinism.

This checks a committed immutable archive twice and includes the first differing
record/field in the failure message. It does not change or relax any readiness
threshold, nor does it certify the archive's completeness.
"""
from __future__ import annotations

import json
from dataclasses import asdict
from pathlib import Path

import pytest

from autopsyx.data import provenance
from autopsyx.providers.store import _encode

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


def test_current_phase3c_archive_phase2_rebuild_is_deterministic():
    if not (ARCHIVE / "manifest.jsonl").exists():
        pytest.skip("the immutable Phase 3C archive is not present in this checkout")

    first = provenance.build(str(ARCHIVE))
    second = provenance.build(str(ARCHIVE))
    difference = _first_difference(first["records"], second["records"])
    assert (
        first["phase2_records_sha256"] == second["phase2_records_sha256"]
        and difference is None
    ), json.dumps(
        {
            "archive": ARCHIVE.name,
            "first_hash": first["phase2_records_sha256"],
            "second_hash": second["phase2_records_sha256"],
            "first_count": len(first["records"]),
            "second_count": len(second["records"]),
            "first_difference": difference,
        },
        sort_keys=True,
    )
