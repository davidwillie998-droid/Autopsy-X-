"""News-to-move attribution.

Given a move onset, look for news around it and decide whether a catalyst
preceded the move, followed it, or coincided with it. Ordering uses the time
the system *saw* the news (``seen_ts``) for tradability, and the publisher's
timestamp (``ts``) for attribution. The two answers are reported separately
because they answer different questions.
"""
from __future__ import annotations

from dataclasses import dataclass, field
from enum import Enum
from typing import Sequence

from ..core.models import NewsEvent
from .taxonomy import EXPECTED_DIRECTION, TIER_CREDIBILITY, EventType


class CatalystTiming(str, Enum):
    NEWS_FIRST = "NEWS_FIRST"
    MOVE_FIRST = "MOVE_FIRST"
    SIMULTANEOUS = "SIMULTANEOUS"
    NO_IDENTIFIED_CATALYST = "NO_IDENTIFIED_CATALYST"
    CONFLICTING_INFORMATION = "CONFLICTING_INFORMATION"


@dataclass
class CatalystAssessment:
    timing: CatalystTiming
    primary_event: NewsEvent | None
    lead_ms: int | None  # onset - publication; positive = news came first
    seen_lead_ms: int | None  # onset - ingestion; positive = we could have known first
    confirmed: bool
    credibility: float | None
    direction_consistent: bool | None
    candidates: list[NewsEvent] = field(default_factory=list)
    reason: str = ""

    @property
    def score(self) -> float:
        """0..1 contribution to Move Quality's catalyst component."""
        if self.primary_event is None or self.timing == CatalystTiming.CONFLICTING_INFORMATION:
            return 0.0
        base = {CatalystTiming.NEWS_FIRST: 1.0, CatalystTiming.SIMULTANEOUS: 0.6,
                CatalystTiming.MOVE_FIRST: 0.25}.get(self.timing, 0.0)
        if self.direction_consistent is False:
            return 0.0
        return base * (self.credibility or 0.0)

    def to_dict(self) -> dict:
        e = self.primary_event
        return {
            "timing": self.timing.value, "lead_ms": self.lead_ms, "seen_lead_ms": self.seen_lead_ms,
            "confirmed": self.confirmed, "credibility": self.credibility,
            "direction_consistent": self.direction_consistent, "score": self.score, "reason": self.reason,
            "primary_event": None if e is None else {"event_id": e.event_id, "headline": e.headline,
                                                     "source": e.source, "tier": e.source_tier,
                                                     "event_type": e.event_type, "ts": e.ts},
            "candidates": [c.event_id for c in self.candidates],
        }


def is_confirmed(story: Sequence[NewsEvent], confirmed_tiers: Sequence[int], min_tier3: int) -> bool:
    """A story is confirmed by one primary/established source, or by several
    independent aggregator sources. Tier-4 posts never confirm anything."""
    if any(e.source_tier in confirmed_tiers for e in story):
        return True
    return len({e.source for e in story if e.source_tier == 3}) >= min_tier3


def assess(token_key: str, onset_ts: int | None, move_direction: int, news: Sequence[NewsEvent],
           cfg: dict) -> CatalystAssessment:
    if onset_ts is None:
        return CatalystAssessment(CatalystTiming.NO_IDENTIFIED_CATALYST, None, None, None, False, None, None,
                                  reason="no move onset")
    lo, hi = onset_ts - cfg["before_window_ms"], onset_ts + cfg["after_window_ms"]
    related = [e for e in news if token_key in e.tokens and lo <= e.ts <= hi]
    if not related:
        return CatalystAssessment(CatalystTiming.NO_IDENTIFIED_CATALYST, None, None, None, False, None, None,
                                  reason="no token-tagged news in window")
    stories: dict[str, list[NewsEvent]] = {}
    for e in related:
        stories.setdefault(e.story_id or e.event_id, []).append(e)

    directions = set()
    for evs in stories.values():
        d = EXPECTED_DIRECTION.get(_etype(evs[0].event_type), 0)
        if d:
            directions.add(d)

    # Primary: earliest report of the most credible story.
    def story_key(evs: list[NewsEvent]):
        best_tier = min(e.source_tier for e in evs)
        first = min(e.ts for e in evs)
        return (best_tier, first)

    best_story = min(stories.values(), key=story_key)
    first = min(best_story, key=lambda e: e.ts)
    confirmed = is_confirmed(best_story, cfg["confirmed_tiers"], cfg["min_independent_tier3"])
    cred = max(TIER_CREDIBILITY.get(e.source_tier, 0.0) for e in best_story)
    if not confirmed:
        cred = min(cred, TIER_CREDIBILITY[4] + 0.1)
    exp_dir = EXPECTED_DIRECTION.get(_etype(first.event_type), 0)
    consistent = None if exp_dir == 0 else exp_dir == move_direction
    lead = onset_ts - first.ts
    seen_lead = onset_ts - min(e.seen_ts for e in best_story)
    tol = cfg["simultaneity_ms"]
    if len(directions) > 1:
        timing = CatalystTiming.CONFLICTING_INFORMATION
        reason = "stories in window imply opposite directions"
    elif abs(lead) <= tol:
        timing, reason = CatalystTiming.SIMULTANEOUS, f"news within {tol} ms of onset"
    elif lead > 0:
        timing, reason = CatalystTiming.NEWS_FIRST, f"news published {lead / 1000:.0f}s before onset"
    else:
        timing, reason = CatalystTiming.MOVE_FIRST, f"move began {-lead / 1000:.0f}s before first report"
    if not confirmed:
        reason += "; story unconfirmed (NEWS_UNVERIFIED)"
    return CatalystAssessment(timing, first, lead, seen_lead, confirmed, cred, consistent, related, reason)


def _etype(v: str) -> EventType:
    try:
        return EventType(v)
    except ValueError:
        return EventType.OTHER
