"""Attention vs artificial attention.

A thousand posts from ten accounts are ten participants. The unit of social
evidence here is the *effective independent author*: distinct authors after
collapsing near-duplicate content and discounting new, low-follower accounts.
"""
from __future__ import annotations

import math
import re
from collections import Counter
from dataclasses import dataclass
from typing import Sequence

from ..core import stats
from ..core.models import SocialPost
from ..core.values import DataStatus, Obs, missing, ok

_WORD = re.compile(r"[a-z0-9$#@]+")


def shingles(text: str, k: int = 3) -> frozenset[str]:
    words = _WORD.findall(text.lower())
    if len(words) < k:
        return frozenset([" ".join(words)])
    return frozenset(" ".join(words[i:i + k]) for i in range(len(words) - k + 1))


def jaccard(a: frozenset[str], b: frozenset[str]) -> float:
    if not a and not b:
        return 1.0
    return len(a & b) / len(a | b)


def content_clusters(posts: Sequence[SocialPost], threshold: float) -> list[list[SocialPost]]:
    """Greedy near-duplicate grouping. O(n * clusters); adequate for per-token windows."""
    reps: list[tuple[frozenset[str], list[SocialPost]]] = []
    for p in posts:
        sh = shingles(p.text)
        for rep, group in reps:
            if jaccard(sh, rep) >= threshold:
                group.append(p)
                break
        else:
            reps.append((sh, [p]))
    return [g for _, g in reps]


@dataclass
class AttentionState:
    mentions: Obs
    mention_velocity: Obs  # mentions now / median of prior windows
    unique_authors: Obs
    effective_authors: Obs
    effective_author_velocity: Obs
    duplicate_ratio: Obs  # 1 - content clusters / posts
    repost_ratio: Obs
    author_hhi: Obs
    new_account_share: Obs
    engagement_per_author: Obs
    artificial_attention_score: Obs  # 0..1
    sentiment: Obs

    def to_dict(self) -> dict:
        return {k: v.to_dict() for k, v in self.__dict__.items()}


def _author_weight(p: SocialPost, now: int, new_ms: int) -> float:
    age_w = 0.3 if p.author_created_ts is not None and now - p.author_created_ts < new_ms else 1.0
    f = p.author_followers or 0
    follow_w = min(1.0, math.log10(f + 10) / 4)  # ~0.25 at 0 followers, 1.0 at 10k
    return age_w * follow_w


def compute(posts: Sequence[SocialPost], as_of: int, cfg: dict, source_available: bool = True) -> AttentionState:
    if not source_available:
        m = missing("no social provider for this token/platform")
        return AttentionState(m, m, m, m, m, m, m, m, m, m, m, m)
    win = cfg["window_ms"]
    cur = [p for p in posts if as_of - win <= p.ts < as_of]
    priors = [[p for p in posts if as_of - (k + 1) * win <= p.ts < as_of - k * win]
              for k in range(1, cfg["baseline_windows"] + 1)]
    have_base = bool(posts) and posts[0].ts <= as_of - cfg["baseline_windows"] * win

    def eff(ps: Sequence[SocialPost]) -> float:
        best: dict[str, float] = {}
        for group in content_clusters([p for p in ps if not p.is_repost], cfg["near_duplicate_jaccard"]):
            # A copy-pasted message counts once, credited to its heaviest author.
            top = max(group, key=lambda p: _author_weight(p, as_of, cfg["new_account_ms"]))
            best[top.author_id] = max(best.get(top.author_id, 0.0), _author_weight(top, as_of, cfg["new_account_ms"]))
        return sum(best.values())

    def vel(now: float, prior: list[float]) -> Obs:
        if not have_base:
            return missing("social history shorter than baseline", DataStatus.INSUFFICIENT_HISTORY)
        return ok((now + 1) / (stats.median(prior) + 1))

    if not cur:
        zero = ok(0.0)
        return AttentionState(zero, vel(0, [len(p) for p in priors]), zero, zero, vel(0, [eff(p) for p in priors]),
                              missing("no posts"), missing("no posts"), missing("no posts"), missing("no posts"),
                              missing("no posts"), missing("no posts"), missing("no posts"))
    authors = Counter(p.author_id for p in cur)
    originals = [p for p in cur if not p.is_repost]
    clusters = content_clusters(originals, cfg["near_duplicate_jaccard"]) if originals else []
    dup = 1 - len(clusters) / len(originals) if originals else 0.0
    rep = 1 - len(originals) / len(cur)
    ahhi = stats.hhi(list(authors.values()))
    new_share = sum(1 for a in {p.author_id: p for p in cur}.values()
                    if a.author_created_ts is not None and as_of - a.author_created_ts < cfg["new_account_ms"]) / len(authors)
    e_now = eff(cur)
    # Artificial attention: duplication, author concentration, new accounts,
    # and a large gap between raw mentions and effective authors.
    gap = 1 - min(1.0, e_now / len(cur))
    artificial = stats.clamp(0.3 * dup + 0.2 * rep + 0.2 * min(1.0, ahhi * 5) + 0.15 * new_share + 0.15 * gap)
    return AttentionState(
        mentions=ok(len(cur)),
        mention_velocity=vel(len(cur), [len(p) for p in priors]),
        unique_authors=ok(len(authors)),
        effective_authors=ok(e_now),
        effective_author_velocity=vel(e_now, [eff(p) for p in priors]),
        duplicate_ratio=ok(dup),
        repost_ratio=ok(rep),
        author_hhi=ok(ahhi),
        new_account_share=ok(new_share),
        engagement_per_author=ok(sum(p.engagement for p in cur) / len(authors)),
        artificial_attention_score=ok(artificial),
        sentiment=missing("sentiment model not configured"),
    )
