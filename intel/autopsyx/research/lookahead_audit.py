"""Adversarial look-ahead audit on a real archive (Phase 2 final gate, tests A-F).

For each sampled decision time t the full decision output (every token's
assessment, signal and the rankings) is computed on the unmodified store,
then recomputed after an adversarial change. A..E must leave it
byte-identical; F runs the same replay twice.
"""
from __future__ import annotations

import dataclasses
import json

from ..core.models import PoolSnapshot, ProviderBar, Side, Swap
from ..pipeline import scan
from ..providers.store import EventStore
from ..ranking import all_rankings


def decision_output(store: EventStore, cfg, t: int, caps) -> str:
    res = scan(store.view(t), cfg, caps=caps)
    return json.dumps({"assessments": {k: a.to_dict() for k, a in sorted(res.assessments.items())},
                       "signals": {k: s.to_dict() for k, s in sorted(res.signals.items())},
                       "rankings": all_rankings(res.assessments)}, sort_keys=True, default=str)


def _store(records) -> EventStore:
    s = EventStore()
    s.extend(records)
    return s


def run(records: list, cfg, caps, times: list[int]) -> dict:
    base_store = _store(records)
    results = []
    for t in times:
        base = decision_output(base_store, cfg, t, caps)
        bars = [r for r in records if isinstance(r, ProviderBar) and r.seen_ts <= t]
        snaps = [r for r in records if isinstance(r, PoolSnapshot) and r.seen_ts <= t]
        swaps = [r for r in records if isinstance(r, Swap) and r.seen_ts <= t]
        ref_bar, ref_snap = bars[-1], snaps[-1]
        checks = {}
        # A: a future bar with an absurd price, seen after t
        fb = dataclasses.replace(ref_bar, ts=ref_bar.ts + 10 * 60_000, seen_ts=t + 11 * 60_000,
                                 open=ref_bar.close, high=ref_bar.close * 50, low=ref_bar.close, close=ref_bar.close * 50,
                                 volume_usd=1e9, raw_id="adversarial")
        checks["A_future_bar"] = decision_output(_store(records + [fb]), cfg, t, caps) == base
        # B: future trades and a new wallet, seen after t
        ft = [Swap(ref_bar.chain, f"adv{i}", 0, t + 60_000 + i, t + 120_000 + i, 0, ref_bar.pool, ref_bar.token,
                   "AdvWa11etAdvWa11etAdvWa11etAdvWa11etAdv111", Side.SELL, 1e12, 1e7, ref_bar.close / 100,
                   "adversarial", "adversarial") for i in range(50)]
        checks["B_future_trade"] = decision_output(_store(records + ft), cfg, t, caps) == base
        # C: future liquidity collapse, seen after t
        fl = dataclasses.replace(ref_snap, ts=t + 60_000, seen_ts=t + 60_000, liquidity_usd=1.0, raw_id="adversarial")
        checks["C_future_liquidity"] = decision_output(_store(records + [fl]), cfg, t, caps) == base
        # D: move available_time of an already-visible record past t: it must vanish from the decision,
        #    i.e. the decision equals one computed with that record deleted outright.
        victim = swaps[-1] if swaps else ref_snap
        moved = [dataclasses.replace(r, seen_ts=t + 1) if r is victim else r for r in records]
        deleted = [r for r in records if r is not victim]
        vis = _store(moved).view(t)
        gone = victim not in (vis.swaps(f"{victim.chain}:{victim.token}") if isinstance(victim, Swap)
                              else vis.pool_snapshots(f"{victim.chain}:{victim.token}"))
        checks["D_timestamp_manipulation"] = gone and (decision_output(_store(moved), cfg, t, caps)
                                                      == decision_output(_store(deleted), cfg, t, caps))
        # E: truncate the archive to what was available at t
        checks["E_truncation"] = decision_output(_store([r for r in records if r.seen_ts <= t]), cfg, t, caps) == base
        # F: identical recomputation
        checks["F_determinism"] = decision_output(_store(records), cfg, t, caps) == base
        results.append({"t": t, **checks})
    names = [k for k in results[0] if k != "t"] if results else []
    return {"times": times, "per_time": results,
            "summary": {n: f"{sum(r[n] for r in results)}/{len(results)} passed" for n in names},
            "all_passed": all(r[n] for r in results for n in names)}
