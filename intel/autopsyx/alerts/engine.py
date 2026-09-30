"""Alerts and audit timelines. Alert text is generated only from measured
numbers in the assessment; there is no free-text generation step that could
invent a reason."""
from __future__ import annotations

from dataclasses import dataclass
from datetime import datetime, timezone
from enum import Enum
from typing import Sequence

from ..assessment import Assessment
from ..core.models import LiquidityKind, Side
from ..detection.move import MoveClass, at_least
from ..narrative.engine import NarrativePhase, NarrativeState
from ..news.catalyst import CatalystTiming
from ..signals.exhaustion import ExhaustionState


class AlertKind(str, Enum):
    BREAKING_MOVE = "BREAKING_MOVE"
    NEWS_CATALYST = "NEWS_CATALYST"
    NARRATIVE_ROTATION = "NARRATIVE_ROTATION"
    DISTRIBUTION = "DISTRIBUTION"
    MANIPULATION_WARNING = "MANIPULATION_WARNING"


@dataclass
class Alert:
    kind: AlertKind
    token: str | None
    ts: int
    text: str
    evidence: dict

    def to_dict(self) -> dict:
        return {"kind": self.kind.value, "token": self.token, "ts": self.ts, "text": self.text, "evidence": self.evidence}


def _v(o):
    return o.value if o is not None and o.ok else None


def _pct(x):
    return "n/a" if x is None else f"{x * 100:+.0f}%"


def token_alerts(a: Assessment, min_flag_confidence: float = 0.3) -> list[Alert]:
    out: list[Alert] = []
    sym = a.token.symbol
    mv = a.move
    if mv.direction and at_least(mv.move_class, MoveClass.SIGNIFICANT):
        mins = (a.as_of - mv.onset_ts) // 60_000 if mv.onset_ts else None
        w15 = a.market.windows.get(15)
        vr = _v(w15.volume_ratio) if w15 else None
        bg = _v(a.participation.buyer_growth)
        lc = _v(a.liquidity.liquidity_change)
        flags = [f.kind for f in a.manipulation.flags]
        text = (f"{sym} moved {_pct(mv.move_since_onset)} in {mins} minutes. "
                f"Volume is {vr:.1f}x baseline. " if vr is not None else f"{sym} moved {_pct(mv.move_since_onset)} in {mins} minutes. ")
        text += f"Unique buyers x{bg:.2f} vs baseline. " if bg is not None else "Buyer baseline unavailable. "
        text += f"Liquidity {_pct(lc)}. " if lc is not None else "Liquidity change unavailable. "
        text += ("Manipulation flags: " + ", ".join(flags) + ".") if flags else "No manipulation flags detected."
        out.append(Alert(AlertKind.BREAKING_MOVE, a.key, a.as_of, text,
                         {"move_class": mv.move_class.value, "abnormality": mv.abnormality,
                          "driving_window": mv.driving_window, "volume_ratio": vr, "buyer_growth": bg,
                          "liquidity_change": lc, "flags": flags}))
    c = a.catalyst
    if c.primary_event and c.timing in (CatalystTiming.NEWS_FIRST, CatalystTiming.SIMULTANEOUS):
        status = "confirmed" if c.confirmed else "UNVERIFIED"
        out.append(Alert(AlertKind.NEWS_CATALYST, a.key, a.as_of,
                         f"{sym} moved {_pct(mv.move_since_onset)} following {status} "
                         f"{c.primary_event.event_type.lower().replace('_', ' ')}: \"{c.primary_event.headline}\" "
                         f"({c.primary_event.source}, tier {c.primary_event.source_tier}).",
                         c.to_dict()))
    if a.exhaustion.state == ExhaustionState.DISTRIBUTION:
        out.append(Alert(AlertKind.DISTRIBUTION, a.key, a.as_of,
                         f"{sym} remains {_pct(mv.move_since_onset)} from onset, but " + "; ".join(a.exhaustion.flags[:3]) + ".",
                         a.exhaustion.to_dict()))
    conc = [f for f in a.manipulation.flags if f.kind in ("volume_concentration", "wash_trading", "coordinated_cluster")
            and f.confidence >= min_flag_confidence]
    if conc and mv.direction > 0 and at_least(mv.move_class, MoveClass.WATCH):
        top = max(conc, key=lambda f: f.confidence)
        share = top.evidence.get("top_k_share") or top.evidence.get("share_of_volume") or top.evidence.get("clustered_buy_share")
        out.append(Alert(AlertKind.MANIPULATION_WARNING, a.key, a.as_of,
                         f"Volume acceleration detected in {sym}, but {share:.0%} of observed volume is concentrated "
                         f"among a small wallet set ({top.kind}, confidence {top.confidence:.2f}). "
                         f"Alternative: {top.alternative_explanation}" if share is not None else
                         f"{sym}: {top.kind} (confidence {top.confidence:.2f}).",
                         top.to_dict()))
    return out


def narrative_alerts(states: Sequence[NarrativeState], as_of: int) -> list[Alert]:
    out = []
    for s in states:
        if s.phase in (NarrativePhase.ACCELERATING, NarrativePhase.EMERGING) and len(s.moving) >= 3:
            out.append(Alert(AlertKind.NARRATIVE_ROTATION, None, as_of,
                             f"{s.narrative} narrative {s.phase.value.split('_')[-1].lower()}: {len(s.moving)} of "
                             f"{s.members} tracked tokens in abnormal up-moves (momentum {s.momentum:.2f}).",
                             s.to_dict()))
    return out


def timeline(a: Assessment, signal_history: Sequence[tuple[int, str]] = ()) -> list[tuple[int, str]]:
    """Evidence trail from the assessment alone (onset, news, signal changes)."""
    events: list[tuple[int, str]] = []
    if a.move.onset_ts:
        events.append((a.move.onset_ts, f"Price leaves local range (move onset, {a.move.driving_window}-bar "
                                        f"window, |z| {a.move.abnormality:.1f})"))
    if a.catalyst.primary_event:
        e = a.catalyst.primary_event
        events.append((e.ts, f"News published: {e.headline} [{e.source}, tier {e.source_tier}]"))
        events.append((e.seen_ts, "News ingested by system"))
    events.extend(signal_history)
    return sorted(events)


def raw_timeline(view, a: Assessment, large_usd: float = 5_000.0, bucket_ms: int = 60_000,
                 signal_history: Sequence[tuple[int, str]] = ()) -> list[tuple[int, str]]:
    """Timeline enriched from raw records: liquidity events, large swaps,
    buyer-rate and mention-rate jumps. Reads the same point-in-time view the
    assessment used, so it cannot show anything the system could not see."""
    start = (a.move.onset_ts or a.as_of) - 30 * 60_000
    ev = list(timeline(a, signal_history))
    for le in view.liquidity_events(a.key):
        if le.ts >= start:
            ev.append((le.ts, f"Liquidity {'added' if le.kind == LiquidityKind.ADD else 'removed'} ${le.usd:,.0f}"))
    buyers_per: dict[int, set[str]] = {}
    large: dict[int, list] = {}
    for s in view.swaps(a.key):
        if s.ts < start:
            continue
        if s.quote_usd >= large_usd:
            large.setdefault(s.ts // bucket_ms, []).append(s)
        if s.side == Side.BUY:
            buyers_per.setdefault(s.ts // bucket_ms, set()).add(s.wallet)
    for b, ss in large.items():
        buys = [s for s in ss if s.side == Side.BUY]
        sells = [s for s in ss if s.side == Side.SELL]
        parts = []
        if buys:
            parts.append(f"{len(buys)} buys ${sum(s.quote_usd for s in buys):,.0f}")
        if sells:
            parts.append(f"{len(sells)} sells ${sum(s.quote_usd for s in sells):,.0f}")
        wallets = len({s.wallet for s in ss})
        ev.append((min(s.ts for s in ss), f"Large-wallet activity: {', '.join(parts)} across {wallets} wallets"))
    ev.extend(_rate_jumps({b: len(w) for b, w in buyers_per.items()}, bucket_ms, "Unique buyers accelerate"))
    mentions: dict[int, int] = {}
    for p in view.social(a.key):
        if p.ts >= start:
            mentions[p.ts // bucket_ms] = mentions.get(p.ts // bucket_ms, 0) + 1
    ev.extend(_rate_jumps(mentions, bucket_ms, "Social mentions increase"))
    return sorted(e for e in ev if e[0] >= start)


def _rate_jumps(counts: dict[int, int], bucket_ms: int, label: str, min_n: int = 5) -> list[tuple[int, str]]:
    out, prev = [], None
    for b in range(min(counts, default=0), max(counts, default=-1) + 1):
        n = counts.get(b, 0)
        if prev is not None and n >= min_n and n >= 2 * max(prev, 1):
            out.append((b * bucket_ms, f"{label} ({prev} -> {n} per {bucket_ms // 1000}s)"))
        prev = n
    return out


def fmt_ts(ts: int) -> str:
    return datetime.fromtimestamp(ts / 1000, tz=timezone.utc).strftime("%H:%M:%S")
