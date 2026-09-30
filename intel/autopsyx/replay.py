"""Deterministic historical replay.

    RAW ARCHIVE -> NORMALIZE -> store.view(t) -> ASSESSMENT -> SIGNAL -> RISK
               -> HYPOTHETICAL POSITION -> EXIT -> JOURNAL

Every (step, token) produces one journal record carrying the token, chain,
assessment time, configuration hash, code version, dataset identifier, signal,
risk state, entry, exit, reason, outcome and data-quality state. The journal
is hash-chained and contains no wall-clock values, so the same dataset, code
and configuration produce a byte-identical journal.

Hypothetical positions are bookkeeping for the exit engine. Their outcomes
are not evidence of strategy quality (docs/REPLAY_PROTOCOL.md).
"""
from __future__ import annotations

import hashlib
import json
from collections import Counter
from dataclasses import dataclass, field
from pathlib import Path

from .backtest.engine import _price_liq
from .core.config import Config
from .detection.move import MoveClass
from .features.liquidity import cpmm_slippage
from .journal.journal import Journal
from .pipeline import FULL, Capabilities, ScanResult, scan
from .providers.store import EventStore
from .ranking import all_rankings
from .risk import engine as risk
from .signals import exit as exit_mod
from .signals.entry import SignalType


class ConfigMismatch(RuntimeError):
    """The loaded configuration is not the one the experiment was declared with."""


@dataclass(frozen=True)
class ReplaySpec:
    start_ts: int
    end_ts: int
    step_ms: int
    dataset_id: str
    code_version: str
    caps: Capabilities = FULL
    expected_config_hash: str | None = None
    latency_ms: int = 60_000


@dataclass
class ReplayResult:
    records: list[dict]
    summary: dict
    journal_path: str | None = None
    digest: str = ""


@dataclass
class _Pos:
    pos: exit_mod.Position
    notional: float
    entry_slip: float
    chain: str


def _outcome(entry_px: float, exit_px: float | None) -> dict:
    if exit_px is None or entry_px <= 0:
        return {"return": None, "note": "no exit price observable"}
    return {"return": exit_px / entry_px - 1,
            "note": "hypothetical; not evidence of strategy quality (Phase 2 measures behaviour only)"}


def feature_status(a) -> dict[str, str]:
    """Availability status (OK / MISSING / STALE / ...) of the inputs the signal gates read."""
    w15 = a.market.windows.get(15)
    drive = a.market.windows.get(a.move.driving_window) if a.move.driving_window else None
    obs = {
        "price": a.market.price, "price_z_driving": drive.z if drive else None,
        "volume_z_15": w15.volume_z if w15 else None, "buy_sell_imbalance_15": w15.buy_sell_imbalance if w15 else None,
        "trades_z_15": w15.trades_z if w15 else None, "unique_buyers": a.participation.unique_buyers,
        "buyer_growth": a.participation.buyer_growth, "independence_ratio": a.participation.independence_ratio,
        "holders": a.participation.holders, "top10_pct": a.participation.top10_pct,
        "creator_pct": a.participation.creator_pct, "liquidity_usd": a.liquidity.liquidity_usd,
        "liquidity_change": a.liquidity.liquidity_change, "est_slippage": a.liquidity.est_slippage,
        "market_cap": a.market.market_cap, "social_mentions": a.social.mentions,
        "narrative_breadth": a.narrative_breadth, "cross_venue": a.cross_venue,
    }
    return {k: (v.status.value if v is not None else "MISSING") for k, v in obs.items()}


def run(store: EventStore, cfg: Config, spec: ReplaySpec, out_dir: str | Path | None = None) -> ReplayResult:
    fp = cfg.fingerprint()
    if spec.expected_config_hash is not None and spec.expected_config_hash != fp:
        raise ConfigMismatch(f"config hash {fp} != declared {spec.expected_config_hash}: new hash = new experiment")
    journal = None
    if out_dir is not None:
        out = Path(out_dir)
        out.mkdir(parents=True, exist_ok=True)
        jp = out / "journal.jsonl"
        if jp.exists():
            first = json.loads(jp.open().readline())
            if first.get("config") != fp:
                raise ConfigMismatch(f"{jp} belongs to config {first.get('config')}; refusing to mix experiments")
            jp.unlink()  # same experiment re-run: rebuild from scratch so the result stays deterministic
        journal = Journal(jp)

    rcfg, xcfg = cfg.section("risk"), cfg.section("exit")
    pf = risk.PortfolioState(equity_usd=rcfg["account_equity_usd"])
    open_: dict[str, _Pos] = {}
    records: list[dict] = []
    prior: ScanResult | None = None
    stats = Counter()
    t = spec.start_ts
    while t <= spec.end_ts:
        res = scan(store.view(t), cfg, prior, caps=spec.caps)
        fill_view = store.view(t + spec.latency_ms)
        ranks = all_rankings(res.assessments, limit=3)
        for key in sorted(res.assessments):
            a, sig = res.assessments[key], res.signals[key]
            rec = {
                "token": key, "chain": a.token.ref.chain, "symbol": a.token.symbol, "as_of": t,
                "configuration_hash": fp, "code_version": spec.code_version, "dataset_id": spec.dataset_id,
                "data_quality": sorted(f.value for f in a.failures),
                "move_class": a.move.move_class.value, "move_direction": a.move.direction,
                "regime": a.regime.regime.value, "exhaustion": a.exhaustion.state.value,
                "lifecycle": a.lifecycle, "token_age_ms": a.token_age_ms, "role": a.role,
                "manipulation_score": a.manipulation.score,
                "manipulation_flags": sorted(f.kind for f in a.manipulation.flags),
                "detectors_unavailable": sorted(a.manipulation.detectors_unavailable),
                "move_quality": a.move_quality.score if a.move_quality else None,
                "move_quality_coverage": a.move_quality.coverage if a.move_quality else None,
                "signal": sig.type.value, "blocked_by": sig.blocked_by,
                "conditions": {c.name: c.passed for c in sig.conditions},
                "feature_status": feature_status(a),
                "ranked_in": sorted(n for n, rows in ranks.items() if any(r["token"] == key for r in rows)),
                "risk": None, "entry": None, "exit": None, "reason": None, "outcome": None,
            }
            stats["assessments"] += 1
            stats[f"signal:{sig.type.value}"] += 1
            stats[f"move:{a.move.move_class.value}"] += 1
            stats[f"regime:{a.regime.regime.value}"] += 1
            stats[f"exhaustion:{a.exhaustion.state.value}"] += 1
            stats[f"lifecycle:{a.lifecycle}"] += 1
            stats[f"role:{a.role}"] += 1
            if any(b.startswith("veto:") for b in sig.blocked_by):
                stats["vetoed"] += 1
            for fl in a.manipulation.flags:
                stats[f"flag:{fl.kind}"] += 1
            for f in a.failures:
                stats[f"failure:{f.value}"] += 1

            if key in open_:
                o = open_[key]
                d = exit_mod.decide(o.pos, a, xcfg)
                rec["reason"] = d.reasons
                final = t + spec.step_ms > spec.end_ts
                if d.action in (exit_mod.ExitAction.EXIT, exit_mod.ExitAction.EMERGENCY_EXIT) or final:
                    px, liq = _price_liq(fill_view, key)
                    action = d.action.value if not final or d.action != exit_mod.ExitAction.HOLD else "END_OF_REPLAY"
                    rec["exit"] = {"action": action, "fill_price": px, "fill_liquidity_usd": liq,
                                   "est_slippage": (cpmm_slippage(o.notional, liq, 0) * rcfg["exit_slippage_multiplier"]
                                                    if liq else None)}
                    rec["outcome"] = _outcome(o.pos.entry_price, px)
                    stats[f"exit:{action}"] += 1
                    pf.open_positions = [p for p in pf.open_positions if p.token != key]
                    del open_[key]
                else:
                    rec["exit"] = {"action": d.action.value}
            elif sig.type == SignalType.HIGH_CONVICTION_CONTINUATION:
                px, liq = _price_liq(fill_view, key)
                pools = store.view(t).pools(key)
                prop = risk.TradeProposal(key, a.token.ref.chain, a.narratives, px or 0.0,
                                          sig.invalidation.get("price_below"), liq,
                                          pools[0].fee_bps if pools else 30.0, a.liquidity.amm_model,
                                          execution_available=px is not None)
                dec = risk.evaluate(prop, pf, rcfg)
                rec["risk"] = dec.to_dict()
                if dec.approved:
                    open_[key] = _Pos(exit_mod.Position(key, t + spec.latency_ms, px, liq, dec.notional_usd / px,
                                                        prop.invalidation_price, a.narratives),
                                      dec.notional_usd, cpmm_slippage(dec.notional_usd, liq, 0), a.token.ref.chain)
                    pf.open_positions.append(risk.OpenPosition(key, a.token.ref.chain, a.narratives, dec.notional_usd))
                    rec["entry"] = {"fill_ts": t + spec.latency_ms, "fill_price": px, "notional_usd": dec.notional_usd}
                    stats["hypothetical_entries"] += 1
                else:
                    stats["risk_refusals"] += 1
            records.append(rec)
            if journal:
                journal.append("replay_assessment", rec, fp)
        prior = res
        t += spec.step_ms

    blob = json.dumps(records, sort_keys=True, default=str).encode()
    summary = {"dataset_id": spec.dataset_id, "configuration_hash": fp, "code_version": spec.code_version,
               "start_ts": spec.start_ts, "end_ts": spec.end_ts, "step_ms": spec.step_ms,
               "capabilities": spec.caps.__dict__, "tokens": len({r["token"] for r in records}),
               "steps": len({r["as_of"] for r in records}), "counts": dict(sorted(stats.items())),
               "records_sha256": hashlib.sha256(blob).hexdigest()}
    result = ReplayResult(records, summary, digest=summary["records_sha256"])
    if out_dir is not None:
        result.journal_path = str(Path(out_dir) / "journal.jsonl")
        (Path(out_dir) / "summary.json").write_text(json.dumps(summary, indent=2, sort_keys=True) + "\n")
    return result


UNCLASSIFIED = MoveClass.UNCLASSIFIED.value
