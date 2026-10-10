"""Narrative membership, momentum and phase."""
from __future__ import annotations

import re
from dataclasses import dataclass, field
from enum import Enum
from typing import Mapping, Sequence

from ..core.models import TokenMeta

# Transparent keyword taxonomy. Assignment is multi-label; manual overrides win.
TAXONOMY: dict[str, tuple[str, ...]] = {
    "ai": ("ai", "gpt", "agent", "neural", "bot", "llm", "agi"),
    "political": ("trump", "maga", "biden", "election", "president", "vote", "kamala"),
    "animal": ("dog", "doge", "shib", "inu", "cat", "pepe", "frog", "bonk", "wif", "hamster", "monkey", "ape"),
    "gaming": ("game", "gaming", "play", "quest", "arena"),
    "depin": ("depin", "node", "wireless", "compute", "storage"),
    "celebrity": ("elon", "musk", "celebrity", "kanye", "drake"),
    "cultural_event": ("olympics", "worldcup", "super bowl", "halloween", "christmas"),
}
CHAIN_NARRATIVES = {"solana": "solana_ecosystem", "ethereum": "ethereum_ecosystem", "base": "base_ecosystem"}


def assign(token: TokenMeta, overrides: Mapping[str, Sequence[str]] | None = None) -> list[str]:
    if overrides and token.ref.key in overrides:
        return list(overrides[token.ref.key])
    text = f"{token.symbol} {token.name} {token.description}".lower()
    words = set(re.findall(r"[a-z]+", text))
    tags = [n for n, kws in TAXONOMY.items() if any(k in words or (len(k) > 3 and k in text) for k in kws)]
    tags.extend(token.narratives_hint)
    tags.append("meme")  # the universe is memecoins; kept explicit so it can be removed
    if token.ref.chain in CHAIN_NARRATIVES:
        tags.append(CHAIN_NARRATIVES[token.ref.chain])
    return sorted(set(tags))


class NarrativePhase(str, Enum):
    DORMANT = "DORMANT"
    EMERGING = "NARRATIVE_EMERGING"
    ACCELERATING = "NARRATIVE_ACCELERATING"
    PEAKING = "NARRATIVE_PEAKING"
    DECAYING = "NARRATIVE_DECAYING"
    INSUFFICIENT_MEMBERS = "INSUFFICIENT_MEMBERS"


@dataclass
class MemberSnapshot:
    token_key: str
    moving_up: bool  # move class >= configured breadth class, direction up
    volume_z: float | None
    buyer_growth: float | None
    social_velocity: float | None
    news_count: int
    is_new_launch: bool
    market_cap: float | None
    volume_usd: float | None


@dataclass
class NarrativeState:
    narrative: str
    members: int
    breadth: float | None  # fraction of members moving up
    momentum: float | None  # 0..1 composite
    prior_momentum: float | None
    phase: NarrativePhase
    aggregate_volume_usd: float
    aggregate_market_cap: float
    new_launches: int
    moving: list[str] = field(default_factory=list)

    def to_dict(self) -> dict:
        d = dict(self.__dict__)
        d["phase"] = self.phase.value
        return d


def _mean_ok(xs: Sequence[float | None]) -> float | None:
    v = [x for x in xs if x is not None]
    return sum(v) / len(v) if v else None


def momentum(members: Sequence[MemberSnapshot]) -> tuple[float | None, float | None]:
    if not members:
        return None, None
    breadth = sum(m.moving_up for m in members) / len(members)
    vz = _mean_ok([m.volume_z for m in members])
    bg = _mean_ok([m.buyer_growth for m in members])
    sv = _mean_ok([m.social_velocity for m in members])
    launches = sum(m.is_new_launch for m in members) / len(members)
    news = min(1.0, sum(m.news_count for m in members) / max(1, len(members)))
    parts = [(0.35, breadth)]
    if vz is not None:
        parts.append((0.2, min(1.0, max(vz, 0) / 4)))
    if bg is not None:
        parts.append((0.2, min(1.0, max(bg - 1, 0) / 2)))
    if sv is not None:
        parts.append((0.1, min(1.0, max(sv - 1, 0) / 3)))
    parts.append((0.1, launches))
    parts.append((0.05, news))
    wsum = sum(w for w, _ in parts)
    return sum(w * v for w, v in parts) / wsum, breadth


def phase(now: float | None, prior: float | None, breadth: float | None) -> NarrativePhase:
    if now is None:
        return NarrativePhase.INSUFFICIENT_MEMBERS
    if prior is None:
        return NarrativePhase.EMERGING if now >= 0.25 else NarrativePhase.DORMANT
    d = now - prior
    if now < 0.2 and d <= 0.02:
        return NarrativePhase.DORMANT if now < 0.1 else NarrativePhase.DECAYING
    if d > 0.05:
        return NarrativePhase.ACCELERATING if now >= 0.45 else NarrativePhase.EMERGING
    if now >= 0.45 and d <= 0.05:
        return NarrativePhase.PEAKING if d > -0.05 else NarrativePhase.DECAYING
    return NarrativePhase.DECAYING if d < -0.05 else NarrativePhase.EMERGING


def evaluate(narrative: str, now: Sequence[MemberSnapshot], prior: Sequence[MemberSnapshot],
             min_members: int) -> NarrativeState:
    if len(now) < min_members:
        return NarrativeState(narrative, len(now), None, None, None, NarrativePhase.INSUFFICIENT_MEMBERS,
                              0.0, 0.0, 0)
    m_now, b = momentum(now)
    m_prior, _ = momentum(prior) if len(prior) >= min_members else (None, None)
    return NarrativeState(
        narrative, len(now), b, m_now, m_prior, phase(m_now, m_prior, b),
        sum(m.volume_usd or 0 for m in now), sum(m.market_cap or 0 for m in now),
        sum(m.is_new_launch for m in now), [m.token_key for m in now if m.moving_up],
    )
