"""Phase 3C data layer: Phase 3A's eligible archives plus any newly acquired,
independently provenance-verified archive. Everything here either calls
frozen Phase 2/3A/3B code directly or reads its output; Phase 3C adds no
normalization, replay, or observation-contract code of its own.
"""
from __future__ import annotations

import json
from pathlib import Path

from ..data import provenance
from ..data.raw import RawStore
from . import phase3a_verify as v3a
from . import phase3b_data as d3b

ROOT = v3a.ROOT
PHASE3C_RUNS_DIR = ROOT / "intel" / "datasets" / "phase3c" / "runs"


def new_archives() -> list[Path]:
    """Phase 3C-acquired archives on disk, in directory-name order."""
    if not PHASE3C_RUNS_DIR.exists():
        return []
    return sorted(p for p in PHASE3C_RUNS_DIR.iterdir() if p.is_dir() and (p / "manifest.jsonl").exists())


def verify_new_archive(d: Path) -> dict:
    """Same provenance check Phase 3A's D2 used: runner hash == rebuild 1 ==
    rebuild 2 == committed canonical files, and acquisition status COMPLETE."""
    v = provenance.verify(str(d))
    meta = (RawStore(d).read_json("run.json") or {})
    v["acquisition_status"] = meta.get("status")
    v["eligible"] = bool(v.get("verified") and meta.get("status") == "COMPLETE")
    return v


def eligible_archives() -> tuple[list[Path], list[dict]]:
    """(included, excluded_report). included = Phase 3A's own eligible archives
    (A, C, D2 -- as its finalized evidence decided, never re-decided here) plus
    every new Phase 3C archive whose own provenance verifies independently."""
    included = list(d3b.eligible_archives())
    excluded = []
    for d in new_archives():
        v = verify_new_archive(d)
        if v["eligible"]:
            included.append(d)
        else:
            excluded.append({"archive": d.name, "reason": "provenance or completion check failed", "detail": v})
    return included, excluded


def token_overlap_across_archives(archives: list[Path]) -> dict:
    """Contamination check: the same token address must not appear in two
    different archives' universes (each archive's own live-poll window should
    have been independent in time)."""
    from . import phase3a_coverage as cov
    by_archive = {}
    for d in archives:
        raw = RawStore(d)
        _, pools = cov.universe(raw)
        by_archive[d.name] = {p["token"] for p in pools}
    overlaps = []
    names = sorted(by_archive)
    for i in range(len(names)):
        for j in range(i + 1, len(names)):
            shared = by_archive[names[i]] & by_archive[names[j]]
            if shared:
                overlaps.append({"archives": [names[i], names[j]], "shared_tokens": sorted(shared)})
    return {"per_archive_token_count": {k: len(v) for k, v in by_archive.items()}, "overlaps": overlaps,
           "contamination_free": not overlaps}
