"""Phase 3B data layer: read-only over the frozen, provenance-verified Phase 3A archives.

Every function here either calls frozen Phase 2/3A code directly (normalize,
replay, the observation parsers, the point-in-time store) or reads its
output; nothing here recomputes normalization, replay, or the observation
contract. The archive set is read from the committed Phase 3A evidence's
own inclusion decision, not hardcoded, so Phase 3B can never silently use
an archive Phase 3A excluded.
"""
from __future__ import annotations

import json
from collections import defaultdict
from dataclasses import dataclass
from pathlib import Path

from ..core.config import Config
from ..core.observation import Availability as A
from ..data.normalize import PHASE2_CAPABILITIES, normalize, replay_window, restrict_to_selection
from ..data.normalize3a import normalize_phase3a
from ..data.raw import RawStore
from . import phase3a_coverage as cov
from . import phase3a_verify as v3a

ROOT = v3a.ROOT
EVIDENCE_PATH = ROOT / "artifacts" / "phase3a" / "PHASE3A_EVIDENCE.json"


def eligible_archives() -> list[Path]:
    """Archives Phase 3A's own finalized evidence included -- never the excluded original D."""
    ev = json.loads(EVIDENCE_PATH.read_text())
    included = set(ev["inclusion"]["included"])
    return [d for d in v3a.archives() if d.name in included]


@dataclass
class AssessmentRow:
    archive: str
    token: str
    chain: str
    step_index: int
    as_of: int
    move_class: str
    move_direction: int
    feature_status: dict


def journal_rows(d: Path, cfg: Config, work: Path, code_version: str) -> list[AssessmentRow]:
    """Re-run the frozen replay (same call phase3a_verify.replay_archive makes) and
    read back its journal. Returns [] for an archive with no live-poll window
    (not replayable) -- never a fabricated or imputed row."""
    raw = RawStore(d)
    records, rep = normalize(str(d))
    win = replay_window(raw)
    if win is None:
        return []
    v3a.replay_archive(d, cfg, work, code_version)  # writes work/d.name/replay_1/journal.jsonl, frozen code path
    jpath = work / d.name / "replay_1" / "journal.jsonl"
    by_token: dict[str, list[AssessmentRow]] = defaultdict(list)
    for line in jpath.read_text().splitlines():
        if not line.strip():
            continue
        p = json.loads(line)["payload"]
        by_token[p["token"]].append(AssessmentRow(
            archive=d.name, token=p["token"], chain=p["chain"], step_index=-1, as_of=p["as_of"],
            move_class=p["move_class"], move_direction=p["move_direction"], feature_status=p["feature_status"]))
    out = []
    for tok, rows in by_token.items():
        rows.sort(key=lambda r: r.as_of)
        for i, r in enumerate(rows):
            out.append(AssessmentRow(r.archive, r.token, r.chain, i, r.as_of, r.move_class, r.move_direction,
                                     r.feature_status))
    return out


def observations_by_token(d: Path) -> dict[str, list]:
    raw = RawStore(d)
    _, pools = cov.universe(raw)
    tokens = {p["token"] for p in pools}
    return cov.observations_by_token(raw, tokens)


def duplicate_and_stale_counts(d: Path) -> dict:
    _, rep = normalize(str(d))
    obs, issues = normalize_phase3a(str(d))
    from collections import Counter
    return {"phase2_duplicate_swaps": rep.duplicate_swaps, "phase2_coverage_gap_count": sum(len(v) for v in rep.coverage_gaps.values()),
           "phase3a_duplicate_observations": sum(1 for i in issues if i.code == "DUPLICATE_OBSERVATION"),
           "phase3a_observation_states": dict(sorted(Counter(f"{o.kind}|{o.state.value}" for o in obs).items()))}
