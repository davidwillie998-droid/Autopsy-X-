"""Raw archive -> normalized, provenance-carrying records + a quality report.

Deterministic: the same run directory always yields byte-identical output.
Nothing is repaired silently; every dropped, derived or flagged value is an
Issue in the report.
"""
from __future__ import annotations

import hashlib
import json
from collections import Counter, defaultdict
from dataclasses import asdict, dataclass, field

from ..core.models import Coverage, PoolInfo, Swap
from ..providers.store import EventStore, _encode
from .providers import dexscreener as ds
from .providers import geckoterminal as gt
from .raw import RawStore
from .validate import Code, Issue


@dataclass
class NormalizationReport:
    run_dir: str
    exchanges: int = 0
    responses_ok: int = 0
    provider_errors: int = 0
    records: dict[str, int] = field(default_factory=dict)
    issues: dict[str, int] = field(default_factory=dict)
    issue_samples: dict[str, list[dict]] = field(default_factory=dict)
    duplicate_swaps: int = 0
    tokens: int = 0
    coverage_gaps: dict[str, list[tuple[int, int]]] = field(default_factory=dict)
    first_response_ms: int | None = None
    last_response_ms: int | None = None
    dataset_sha256: str = ""

    def to_dict(self) -> dict:
        return asdict(self)


def _parse(e, body: bytes, lag_ms: int):
    if e.endpoint in ("gt.new_pools", "gt.trending", "gt.top_pools", "gt.pools_multi"):
        return gt.parse_pools(e, body)
    if e.endpoint == "gt.trades":
        return gt.parse_trades(e, body, lag_ms)
    if e.endpoint == "gt.ohlcv":
        return gt.parse_ohlcv(e, body, lag_ms)
    if e.endpoint == "gt.token_info":
        return gt.parse_token_info(e, body)
    if e.endpoint == "ds.pairs":
        return ds.parse_pairs(e, body)
    return None


def coverage_gaps(covs: list[Coverage], lo: int, hi: int) -> list[tuple[int, int]]:
    """Intervals inside [lo, hi) not covered by any claim."""
    gaps, cur = [], lo
    for c in sorted(covs, key=lambda c: c.start_ts):
        if c.start_ts > cur:
            gaps.append((cur, min(c.start_ts, hi)))
        cur = max(cur, c.end_ts)
        if cur >= hi:
            break
    if cur < hi:
        gaps.append((cur, hi))
    return [g for g in gaps if g[1] > g[0]]


def normalize(run_dir: str, lag_ms: int = 60_000) -> tuple[list, NormalizationReport]:
    raw = RawStore(run_dir)
    rep = NormalizationReport(run_dir)
    records: list = []
    issues: list[Issue] = []
    last_resp = None
    for e in raw.entries():
        rep.exchanges += 1
        if e.error or e.raw_id is None:
            if e.provider != "audit":
                rep.provider_errors += 1
                issues.append(Issue(Code.PROVIDER_ERROR, None, f"{e.endpoint} {e.url}: {e.error}", "skipped_response"))
            else:
                issues.append(Issue(Code.PAGINATION_GAP, None, e.error or "", "flagged"))
            continue
        if e.status is not None and e.status != 200:
            issues.append(Issue(Code.PROVIDER_ERROR, e.raw_id, f"{e.endpoint}: HTTP {e.status}", "skipped_response"))
            continue
        if last_resp is not None and e.response_ts < last_resp:
            issues.append(Issue(Code.OUT_OF_ORDER, e.raw_id, f"seq {e.seq} response_ts earlier than previous", "flagged"))
        last_resp = e.response_ts if last_resp is None else max(last_resp, e.response_ts)
        rep.responses_ok += 1
        rep.first_response_ms = e.response_ts if rep.first_response_ms is None else min(rep.first_response_ms, e.response_ts)
        rep.last_response_ms = max(rep.last_response_ms or 0, e.response_ts)
        parsed = _parse(e, raw.body(e.raw_id), lag_ms)
        if parsed is None:
            issues.append(Issue(Code.MALFORMED_RECORD, e.raw_id, f"no parser for {e.endpoint}", "skipped_response"))
            continue
        records.extend(parsed.records)
        issues.extend(parsed.issues)

    # Duplicate observations: the same swap returned by consecutive polls. Expected by design;
    # the earliest-seen copy is kept downstream (quality.dedupe_swaps). Counted here, not dropped.
    uid_count = Counter(r.uid for r in records if isinstance(r, Swap))
    rep.duplicate_swaps = sum(c - 1 for c in uid_count.values())
    if rep.duplicate_swaps:
        issues.append(Issue(Code.DUPLICATE_OBSERVATION, None,
                            f"{rep.duplicate_swaps} repeat observations of already-seen swaps (poll overlap); "
                            f"earliest-seen copy kept by the quality gate", "flagged"))

    # Conflicting pool metadata between responses.
    meta: dict[str, set] = defaultdict(set)
    for r in records:
        if isinstance(r, PoolInfo):
            meta[r.pool].add((r.token, r.venue, r.created_ts))
    for pool, vals in meta.items():
        if len(vals) > 1:
            issues.append(Issue(Code.CONFLICTING_METADATA, None, f"pool {pool}: {sorted(vals)}", "flagged"))

    # Trade-coverage gaps per token over the collection window.
    if rep.first_response_ms is not None:
        by_tok: dict[str, list[Coverage]] = defaultdict(list)
        for r in records:
            if isinstance(r, Coverage) and r.kind == "trades":
                by_tok[f"{r.chain}:{r.token}"].append(r)
        for k, covs in sorted(by_tok.items()):
            lo = min(c.start_ts for c in covs)
            gaps = coverage_gaps(covs, lo, max(c.end_ts for c in covs))
            if gaps:
                rep.coverage_gaps[k] = gaps
                issues.append(Issue(Code.COVERAGE_GAP, None, f"{k}: {len(gaps)} trade-coverage gap(s)", "flagged"))

    counts = Counter(type(r).__name__ for r in records)
    rep.records = dict(sorted(counts.items()))
    ic = Counter(i.code for i in issues)
    rep.issues = dict(sorted(ic.items()))
    for code in rep.issues:
        rep.issue_samples[code] = [i.to_dict() for i in issues if i.code == code][:5]
    rep.tokens = len({r.ref.key for r in records if type(r).__name__ == "TokenMeta"})
    h = hashlib.sha256()
    for r in records:
        h.update(json.dumps(_encode(asdict(r)), sort_keys=True, default=str).encode())
    rep.dataset_sha256 = h.hexdigest()
    return records, rep


def to_store(records: list) -> EventStore:
    s = EventStore()
    s.extend(records)
    return s
