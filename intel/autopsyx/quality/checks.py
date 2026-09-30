"""Data-quality gate. Runs before any feature is computed.

Outputs a report listing failure modes; downstream stages read it and the
signal engine refuses to fire on blocking modes.
"""
from __future__ import annotations

from collections import Counter, defaultdict
from dataclasses import dataclass, field
from typing import Iterable, Sequence

from ..core.failure import FailureMode
from ..core.models import PoolSnapshot, Swap, TokenMeta


@dataclass
class QualityReport:
    token_key: str
    failures: set[FailureMode] = field(default_factory=set)
    notes: list[str] = field(default_factory=list)
    duplicates_removed: int = 0
    unconfirmed_dropped: int = 0

    def flag(self, mode: FailureMode, note: str) -> None:
        self.failures.add(mode)
        self.notes.append(f"{mode.value}: {note}")

    def to_dict(self) -> dict:
        return {
            "token": self.token_key,
            "failures": sorted(f.value for f in self.failures),
            "notes": self.notes,
            "duplicates_removed": self.duplicates_removed,
            "unconfirmed_dropped": self.unconfirmed_dropped,
        }


def dedupe_swaps(swaps: Sequence[Swap], report: QualityReport) -> list[Swap]:
    """Same (chain, tx, log_index) delivered twice (websocket + backfill overlap)
    is one swap. Keep the earliest-seen copy."""
    seen: dict[tuple, Swap] = {}
    for s in swaps:
        prev = seen.get(s.uid)
        if prev is None or s.seen_ts < prev.seen_ts:
            seen[s.uid] = s
    report.duplicates_removed += len(swaps) - len(seen)
    return sorted(seen.values(), key=lambda x: (x.ts, x.log_index))


def drop_unconfirmed(swaps: Sequence[Swap], head_block: int | None, min_conf: int,
                     report: QualityReport) -> list[Swap]:
    """Reorg safety: ignore swaps shallower than the chain's confirmation depth.
    If head_block is unknown, pass through but note it."""
    if head_block is None:
        report.notes.append("head block unknown; reorg filter not applied")
        return list(swaps)
    kept = [s for s in swaps if head_block - s.block >= min_conf]
    report.unconfirmed_dropped += len(swaps) - len(kept)
    return kept


def check_timestamps(swaps: Iterable[Swap], max_skew_ms: int, as_of: int, report: QualityReport) -> None:
    bad_future = [s for s in swaps if s.ts > as_of + max_skew_ms]
    bad_order = [s for s in swaps if s.ts > s.seen_ts + max_skew_ms]
    if bad_future:
        report.flag(FailureMode.CONFLICTING_DATA, f"{len(bad_future)} swaps timestamped after as_of")
    if bad_order:
        report.flag(FailureMode.CONFLICTING_DATA, f"{len(bad_order)} swaps claim ts later than ingestion")


def check_staleness(snapshots: Sequence[PoolSnapshot], swaps: Sequence[Swap], as_of: int,
                    max_age_ms: int, report: QualityReport) -> None:
    last = max([s.ts for s in snapshots] + [s.ts for s in swaps], default=None)
    if last is None:
        report.flag(FailureMode.NO_DATA, "no price observations")
    elif as_of - last > max_age_ms:
        report.flag(FailureMode.STALE_DATA, f"last price {as_of - last} ms old (max {max_age_ms})")


def check_cross_source(snapshots: Sequence[PoolSnapshot], as_of: int, window_ms: int,
                       tolerance: float, report: QualityReport) -> None:
    """Compare the latest price from each source inside the window."""
    latest: dict[str, PoolSnapshot] = {}
    for s in snapshots:
        if as_of - s.ts <= window_ms and s.source:
            if s.source not in latest or s.ts > latest[s.source].ts:
                latest[s.source] = s
    prices = [s.price_usd for s in latest.values() if s.price_usd > 0]
    if len(prices) >= 2:
        lo, hi = min(prices), max(prices)
        if (hi - lo) / lo > tolerance:
            report.flag(FailureMode.CONFLICTING_DATA,
                        f"sources disagree by {(hi - lo) / lo:.1%} ({sorted(latest)})")


def symbol_collisions(tokens: Sequence[TokenMeta]) -> dict[str, list[str]]:
    """Symbol -> list of token keys when more than one address uses it.
    The UI must show the address whenever a symbol is ambiguous."""
    by_sym: dict[str, list[str]] = defaultdict(list)
    for t in tokens:
        by_sym[t.symbol.upper()].append(t.ref.key)
    return {s: keys for s, keys in by_sym.items() if len(keys) > 1}


def block_gaps(blocks: Sequence[int], max_gap: int) -> list[tuple[int, int]]:
    """Gaps in observed block numbers larger than max_gap. On busy tokens a gap
    usually means the ingestor dropped data, not that nobody traded."""
    ordered = sorted(set(blocks))
    return [(a, b) for a, b in zip(ordered, ordered[1:]) if b - a > max_gap]


def run(token_key: str, swaps: Sequence[Swap], snapshots: Sequence[PoolSnapshot], as_of: int,
        cfg: dict, head_block: int | None = None) -> tuple[list[Swap], QualityReport]:
    report = QualityReport(token_key)
    chain = token_key.split(":", 1)[0]
    clean = dedupe_swaps(swaps, report)
    clean = drop_unconfirmed(clean, head_block, cfg["min_confirmations"].get(chain, 0), report)
    check_timestamps(clean, cfg["max_clock_skew_ms"], as_of, report)
    check_staleness(snapshots, clean, as_of, cfg["max_price_age_ms"], report)
    check_cross_source(snapshots, as_of, cfg["max_price_age_ms"], cfg["cross_source_price_tolerance"], report)
    counts = Counter(s.tx_hash for s in clean)
    if counts and max(counts.values()) > 50:
        report.notes.append("a single transaction contains >50 swaps of this token (router batching or bot)")
    return clean, report
