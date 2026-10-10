"""Signal journal and outcome labelling (the learning engine's raw material).

Records are append-only JSONL with a content hash chain, so a later edit to
history is detectable. Outcome labels are assigned by fixed rules; changing a
rule is a versioned research change, never an automatic update.
"""
from __future__ import annotations

import hashlib
import json
from dataclasses import dataclass, field
from enum import Enum
from pathlib import Path
from typing import Sequence

from ..core.models import Bar

LABEL_RULES_VERSION = "1"


class Outcome(str, Enum):
    FALSE_BREAKOUT = "FALSE_BREAKOUT"
    SUCCESSFUL_CONTINUATION = "SUCCESSFUL_CONTINUATION"
    NEWS_DRIVEN = "NEWS_DRIVEN"
    SOCIAL_DRIVEN = "SOCIAL_DRIVEN"
    MANIPULATION_DRIVEN = "MANIPULATION_DRIVEN"
    LIQUIDITY_FAILURE = "LIQUIDITY_FAILURE"
    EXHAUSTION = "EXHAUSTION"
    UNKNOWN = "UNKNOWN"


@dataclass
class TradeOutcome:
    mfe: float | None  # max favourable excursion (fraction)
    mae: float | None  # max adverse excursion (fraction, negative)
    duration_ms: int | None
    exit_reason: str
    realized_return: float | None
    labels: list[Outcome] = field(default_factory=list)


def excursions(entry_price: float, bars: Sequence[Bar]) -> tuple[float | None, float | None]:
    highs = [b.high for b in bars if b.high is not None]
    lows = [b.low for b in bars if b.low is not None]
    if not highs or entry_price <= 0:
        return None, None
    return max(highs) / entry_price - 1, min(lows) / entry_price - 1


def label(outcome: TradeOutcome, *, catalyst_timing: str, catalyst_confirmed: bool, social_led: bool,
          manipulation_score: float, liquidity_drop: float | None, exhaustion_state: str,
          success_threshold: float = 0.2, false_breakout_mae: float = -0.1) -> list[Outcome]:
    """Multi-label, deterministic. A trade can be NEWS_DRIVEN and a FALSE_BREAKOUT."""
    labs: list[Outcome] = []
    r, mfe, mae = outcome.realized_return, outcome.mfe, outcome.mae
    if liquidity_drop is not None and liquidity_drop >= 0.3:
        labs.append(Outcome.LIQUIDITY_FAILURE)
    if mfe is not None and mae is not None:
        if mfe >= success_threshold and (r or 0) > 0:
            labs.append(Outcome.SUCCESSFUL_CONTINUATION)
        elif mfe < success_threshold / 2 and mae <= false_breakout_mae:
            labs.append(Outcome.FALSE_BREAKOUT)
    if exhaustion_state in ("EXHAUSTION_RISK", "DISTRIBUTION") and (r or 0) <= 0:
        labs.append(Outcome.EXHAUSTION)
    if catalyst_timing in ("NEWS_FIRST", "SIMULTANEOUS") and catalyst_confirmed:
        labs.append(Outcome.NEWS_DRIVEN)
    if social_led:
        labs.append(Outcome.SOCIAL_DRIVEN)
    if manipulation_score >= 0.5:
        labs.append(Outcome.MANIPULATION_DRIVEN)
    return labs or [Outcome.UNKNOWN]


class Journal:
    def __init__(self, path: str | Path):
        self.path = Path(path)
        self._prev = self._last_hash()

    def _last_hash(self) -> str:
        if not self.path.exists():
            return "genesis"
        last = "genesis"
        with open(self.path) as fh:
            for line in fh:
                if line.strip():
                    last = json.loads(line)["hash"]
        return last

    def append(self, kind: str, payload: dict, config_fingerprint: str) -> str:
        body = {"kind": kind, "config": config_fingerprint, "label_rules": LABEL_RULES_VERSION,
                "prev": self._prev, "payload": payload}
        blob = json.dumps(body, sort_keys=True, default=str)
        h = hashlib.sha256(blob.encode()).hexdigest()
        with open(self.path, "a") as fh:
            fh.write(json.dumps({**body, "hash": h}, default=str) + "\n")
        self._prev = h
        return h

    def verify(self) -> bool:
        prev = "genesis"
        with open(self.path) as fh:
            for line in fh:
                if not line.strip():
                    continue
                rec = json.loads(line)
                h = rec.pop("hash")
                if rec["prev"] != prev:
                    return False
                if hashlib.sha256(json.dumps(rec, sort_keys=True, default=str).encode()).hexdigest() != h:
                    return False
                prev = h
        return True
