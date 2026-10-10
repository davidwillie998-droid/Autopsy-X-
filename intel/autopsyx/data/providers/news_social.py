"""Keyless news (GDELT DOC 2.0) and social (Reddit public JSON) acquisition.

Provenance only: no sentiment, no scoring, no relevance judgement. Each item
records who said it, where, its URL and a content hash, and three separate
clocks:

  publication_time  when the author published (Reddit ``created_utc``);
                    GDELT does not provide it, so it is NOT_OBSERVED there
  source_ts         the provider's own timestamp: Reddit creation time,
                    GDELT ``seendate`` (its crawler's first sighting)
  ingestion_ts      when our response arrived; never used as either of the above

The token reference is the query that found the item
(``reference_method``); whether the text truly concerns the token is not
verified here and is recorded as UNKNOWN.

X (Twitter) and Telegram need credentials this project does not hold; they
are reported UNAVAILABLE in the coverage matrix, not silently replaced.
"""
from __future__ import annotations

import hashlib
import json
from datetime import datetime, timezone
from urllib.parse import quote, urlsplit

from ...core.observation import Availability as A
from ...core.observation import Observation, validate
from ..raw import ManifestEntry
from ..validate import Code, Issue
from .solana_rpc import Parsed

GDELT = "gdelt"
GDELT_BASE = "https://api.gdeltproject.org/api/v2"
REDDIT = "reddit"
REDDIT_BASE = "https://www.reddit.com"
HEADERS = {"User-Agent": "autopsyx-research/0.3 (read-only research collector)"}
UNAVAILABLE_SOURCES = {"x": "requires a paid API key", "telegram": "requires an authenticated client session"}


def gdelt_query(symbol: str) -> str | None:
    """GDELT rejects terms shorter than three characters."""
    s = (symbol or "").strip()
    return f'"{s}" solana' if len(s) >= 3 else None


def path_gdelt(query: str, max_records: int = 75, timespan: str = "1d") -> str:
    return (f"/doc/doc?query={quote(query)}&mode=artlist&format=json&maxrecords={max_records}"
            f"&sort=datedesc&timespan={timespan}")


def path_reddit(query: str, limit: int = 50, window: str = "week") -> str:
    return f"/search.json?q={quote(query)}&sort=new&limit={limit}&t={window}&raw_json=1"


def _sha(*parts) -> str:
    return hashlib.sha256("\x1f".join(p or "" for p in parts).encode()).hexdigest()


def _empty(e: ManifestEntry, kind: str, provider: str, state: A, reason: str) -> Observation:
    t = e.response_ts if e.response_ts is not None else e.request_ts
    return validate(Observation(kind=kind, entity=e.context.get("token", ""), chain=e.context.get("chain", "solana"),
                                venue=None, state=state, observation_ts=t, source_ts=None,
                                source_ts_state=A.NOT_OBSERVED, ingestion_ts=t, provider=provider,
                                response_status=e.status, raw_id=e.raw_id, reason=reason))


def _load(e: ManifestEntry, body: bytes | None, kind: str, provider: str, out: Parsed):
    if body is None:
        out.observations.append(_empty(e, kind, provider, A.ERROR, f"request failed: {e.error}"))
        return None
    try:
        return json.loads(body.decode())
    except (UnicodeDecodeError, ValueError) as exc:
        # GDELT answers query errors with a plain-text 200 body
        text = body[:120].decode("utf-8", "replace").strip()
        out.observations.append(_empty(e, kind, provider, A.ERROR, f"non-JSON body: {text!r}"))
        out.issues.append(Issue(Code.MALFORMED_RECORD, e.raw_id, f"{provider}: {exc}", "skipped_response"))
        return None


def parse_gdelt(e: ManifestEntry, body: bytes | None) -> Parsed:
    out = Parsed()
    doc = _load(e, body, "news", GDELT, out)
    if doc is None:
        return out
    arts = doc.get("articles") if isinstance(doc, dict) else None
    if not arts:
        out.observations.append(_empty(e, "news", GDELT, A.NOT_OBSERVED, f"no articles for {e.context.get('query')!r}"))
        return out
    for a in arts:
        url, seen = a.get("url"), a.get("seendate")
        try:
            seen_ms = int(datetime.strptime(seen, "%Y%m%dT%H%M%SZ").replace(tzinfo=timezone.utc).timestamp() * 1000)
        except (TypeError, ValueError):
            seen_ms = None
        if not isinstance(url, str) or not url.startswith("http"):
            out.issues.append(Issue(Code.MALFORMED_RECORD, e.raw_id, f"gdelt article url {url!r}", "dropped_record"))
            continue
        if seen_ms is not None and seen_ms > e.response_ts + 5_000:
            out.issues.append(Issue(Code.IMPOSSIBLE_TIMESTAMP, e.raw_id, f"seendate {seen} after response", "dropped_field"))
            seen_ms = None
        title = a.get("title")
        out.observations.append(validate(Observation(
            kind="news", entity=e.context.get("token", ""), chain=e.context.get("chain", "solana"), venue=None,
            state=A.OBSERVED, observation_ts=seen_ms if seen_ms is not None else e.response_ts,
            source_ts=seen_ms, source_ts_state=A.OBSERVED if seen_ms is not None else A.NOT_OBSERVED,
            ingestion_ts=e.response_ts, provider=GDELT, response_status=e.status, raw_id=e.raw_id,
            value={"title": title, "url": url, "domain": a.get("domain") or urlsplit(url).hostname,
                   "author": None, "author_state": A.NOT_OBSERVED.value,
                   "language": a.get("language"), "source_country": a.get("sourcecountry"),
                   "content_sha256": _sha(title, url), "content_hashed": "title+url",
                   "publication_time": None, "publication_time_state": A.NOT_OBSERVED.value,
                   "source_ts_meaning": "gdelt seendate (crawler first sighting), not publication time",
                   "event_type": "article", "referenced_token": e.context.get("token"),
                   "reference_method": f"provider_search:{e.context.get('query')}",
                   "reference_verified_state": A.UNKNOWN.value})))
    return out


def parse_reddit(e: ManifestEntry, body: bytes | None) -> Parsed:
    out = Parsed()
    doc = _load(e, body, "social", REDDIT, out)
    if doc is None:
        return out
    try:
        children = doc["data"]["children"]
    except (KeyError, TypeError):
        out.observations.append(_empty(e, "social", REDDIT, A.ERROR, "malformed listing: no data.children"))
        out.issues.append(Issue(Code.MALFORMED_RECORD, e.raw_id, "reddit listing without data.children", "skipped_response"))
        return out
    if not children:
        out.observations.append(_empty(e, "social", REDDIT, A.NOT_OBSERVED, f"no posts for {e.context.get('query')!r}"))
        return out
    for c in children:
        d = c.get("data") if isinstance(c, dict) else None
        if not isinstance(d, dict) or not d.get("permalink"):
            out.issues.append(Issue(Code.MALFORMED_RECORD, e.raw_id, "reddit child without permalink", "dropped_record"))
            continue
        cu = d.get("created_utc")
        pub = int(cu * 1000) if isinstance(cu, (int, float)) else None
        if pub is not None and pub > e.response_ts + 5_000:
            out.issues.append(Issue(Code.IMPOSSIBLE_TIMESTAMP, e.raw_id, f"created_utc {cu} after response", "dropped_field"))
            pub = None
        author = d.get("author")
        author = None if author in (None, "[deleted]") else author
        url = REDDIT_BASE + d["permalink"]
        out.observations.append(validate(Observation(
            kind="social", entity=e.context.get("token", ""), chain=e.context.get("chain", "solana"),
            venue=d.get("subreddit"), state=A.OBSERVED, observation_ts=pub if pub is not None else e.response_ts,
            source_ts=pub, source_ts_state=A.OBSERVED if pub is not None else A.NOT_OBSERVED,
            ingestion_ts=e.response_ts, provider=REDDIT, response_status=e.status, raw_id=e.raw_id,
            value={"platform": "reddit", "author": author, "author_state": A.OBSERVED.value if author else A.NOT_OBSERVED.value,
                   "url": url, "post_id": d.get("name") or d.get("id"), "linked_url": d.get("url"),
                   "content_sha256": _sha(d.get("title"), d.get("selftext")), "content_hashed": "title+selftext",
                   "publication_time": pub, "publication_time_state": A.OBSERVED.value if pub is not None else A.NOT_OBSERVED.value,
                   "event_type": "post", "referenced_token": e.context.get("token"),
                   "reference_method": f"provider_search:{e.context.get('query')}",
                   "reference_verified_state": A.UNKNOWN.value})))
    return out
