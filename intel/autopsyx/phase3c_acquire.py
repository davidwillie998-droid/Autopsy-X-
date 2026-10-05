"""Phase 3C.1 protected-window acquisition scheduler.

The frozen Phase 3C acquisition engine remains the provider implementation.
This module only changes scheduling: discovery/backfill/enrichment are bounded
by a pre-replay deadline, while a protected replay allocation is reserved
before any enrichment work begins.
"""
from __future__ import annotations

import argparse
import json
import logging
import os
import time
from dataclasses import asdict
from typing import Callable

from .data import acquire
from .data.providers import geckoterminal as gt
from .data.providers import solana_rpc as rpc
from .data.raw import RawStore

log = logging.getLogger("autopsyx.phase3c1")

DEFAULT_REPLAY_RESERVE_S = 1800
DEFAULT_ENRICHMENT_GUARD_S = 180


def _deadline_reached(now_ms: Callable[[], int], deadline_ms: int) -> bool:
    return now_ms() >= deadline_ms


def _bounded_backfill(f: acquire.Fetcher, plan: acquire.Plan, picked: list[dict],
                      deadline_ms: int, now_ms: Callable[[], int]) -> dict:
    """Backfill only while the pre-replay budget remains."""
    pages = 0
    stopped = False
    for p in picked:
        if _deadline_reached(now_ms, deadline_ms):
            stopped = True
            break
        ctx = {"chain": plan.network, "pool": p["pool"], "token": p["token"]}
        before = None
        for page in range(plan.backfill_pages):
            if _deadline_reached(now_ms, deadline_ms):
                stopped = True
                break
            e, b = f.get(gt.NAME, "gt.ohlcv", gt.path_ohlcv(plan.network, p["pool"], 1000, before),
                         {**ctx, "page": page, "phase3c1": "pre_replay_backfill"})
            pages += 1
            if b is None:
                break
            bars = [r for r in gt.parse_ohlcv(e, b, plan.lag_ms).records
                    if type(r).__name__ == "ProviderBar"]
            if len(bars) < 900:
                break
            before = min(x.ts for x in bars) // 1000
        if stopped:
            break
        if _deadline_reached(now_ms, deadline_ms):
            stopped = True
            break
        f.get(gt.NAME, "gt.token_info", gt.path_token_info(plan.network, p["token"]),
              {**ctx, "pool_created_ts": p["created_ts"], "total_supply": p["total_supply"],
               "phase3c1": "pre_replay_backfill"})
    return {"pages": pages, "stopped_by_deadline": stopped}


def _bounded_enrichment(f: acquire.Fetcher, plan: acquire.Plan, picked: list[dict],
                        round_: int, deadline_ms: int, now_ms: Callable[[], int],
                        guard_s: int) -> tuple[list[dict], bool]:
    """Enrich token-by-token and refuse to start another token inside the guard.

    A token enrichment is intentionally atomic. The guard is conservative so a
    long provider call cannot consume the protected replay reservation.
    """
    out: list[dict] = []
    stopped = False
    guard_ms = max(0, guard_s) * 1000
    for p in picked:
        if now_ms() + guard_ms >= deadline_ms:
            stopped = True
            break
        out.extend(acquire.enrich(f, plan, [p], round_))
    return out, stopped


def run(run_dir: str, plan: acquire.Plan, *, replay_reserve_s: int = DEFAULT_REPLAY_RESERVE_S,
        enrichment_guard_s: int = DEFAULT_ENRICHMENT_GUARD_S,
        clients: dict | None = None,
        now_ms: Callable[[], int] = lambda: int(time.time() * 1000),
        sleep: Callable[[float], None] = time.sleep,
        max_cycles: int | None = None) -> dict:
    """Run a Phase 3C.1 acquisition with a protected replay allocation."""
    if replay_reserve_s <= 0:
        raise ValueError("replay_reserve_s must be positive")
    if plan.duration_s <= replay_reserve_s:
        raise ValueError("duration_s must exceed replay_reserve_s")

    raw = RawStore(run_dir)
    f = acquire.Fetcher(raw, clients or acquire.default_clients(plan, now_ms), now_ms, sleep,
                        plan.circuit_waits, display={rpc.NAME: rpc.display_base(rpc.BASE)})
    started = now_ms()
    total_deadline = started + plan.duration_s * 1000
    replay_deadline = total_deadline
    pre_replay_deadline = total_deadline - replay_reserve_s * 1000

    meta = {
        "started_ms": started,
        "plan": asdict(plan),
        "code_version": os.environ.get("GITHUB_SHA", "local"),
        "runner": os.environ.get("RUNNER_NAME", "local"),
        "execution": "none: acquisition only, no orders",
        "scheduler": {
            "name": "phase3c1-protected-replay",
            "total_duration_s": plan.duration_s,
            "replay_reserve_s": replay_reserve_s,
            "enrichment_guard_s": enrichment_guard_s,
            "pre_replay_deadline_ms": pre_replay_deadline,
            "protected_replay_deadline_ms": replay_deadline,
        },
    }
    raw.write_json("run.json", meta)

    if plan.universe_file:
        u = acquire.load_universe(plan.universe_file)
        raw.write_json("universe.json", u)
        picked = [{**p, "total_supply": u["metadata"][p["token"]]["total_supply_at_selection"]}
                  for p in u["pools"]]
        meta["universe"] = {"source": "reused", "fingerprint": u["fingerprint"], "from": plan.universe_file}
    else:
        if plan.phase3a:
            u = acquire.freeze_universe(f, plan)
            meta["universe"] = {"source": "frozen_this_run", "fingerprint": u["fingerprint"]}
            picked = [{**p, "total_supply": u["metadata"][p["token"]]["total_supply_at_selection"]}
                      for p in u["pools"]]
        else:
            u = acquire.select_universe(f, plan)
            picked = u["picked"]

    if not picked:
        meta["status"] = "BLOCKED: no pools selectable (discovery failed)"
        meta["ended_ms"] = now_ms()
        raw.write_json("run.json", meta)
        return meta

    meta["pre_replay"] = {}
    meta["pre_replay"]["backfill"] = _bounded_backfill(f, plan, picked, pre_replay_deadline, now_ms)

    if plan.phase3a and not _deadline_reached(now_ms, pre_replay_deadline):
        enrichment, stopped = _bounded_enrichment(
            f, plan, picked, 0, pre_replay_deadline, now_ms, enrichment_guard_s
        )
        meta["enrichment"] = enrichment
        meta["pre_replay"]["enrichment_stopped_by_deadline"] = stopped
    else:
        meta["enrichment"] = []
        meta["pre_replay"]["enrichment_stopped_by_deadline"] = True

    replay_started = now_ms()
    meta["scheduler"]["replay_started_ms"] = replay_started
    meta["scheduler"]["replay_planned_s"] = max(0, (replay_deadline - replay_started) / 1000)
    raw.write_json("run.json", meta)

    cycle = 0
    while True:
        t0 = now_ms()
        if t0 >= replay_deadline or (max_cycles is not None and cycle >= max_cycles):
            break
        acquire.poll_cycle(f, plan, picked, cycle)
        cycle += 1
        spent = (now_ms() - t0) / 1000
        remaining = (replay_deadline - now_ms()) / 1000
        if remaining <= 0:
            break
        if spent < plan.cycle_s:
            sleep(min(plan.cycle_s - spent, remaining))

    replay_ended = now_ms()
    replay_actual_s = max(0, (replay_ended - replay_started) / 1000)
    meta["scheduler"].update({
        "replay_ended_ms": replay_ended,
        "replay_actual_s": replay_actual_s,
        "replay_reserve_s": replay_reserve_s,
        "replay_reserve_met": replay_actual_s >= replay_reserve_s,
    })

    entries = raw.entries()
    meta.update({
        "ended_ms": replay_ended,
        "cycles": cycle,
        "exchanges": len(entries),
        "circuit_waits": f.waited,
        "final_gt_rate_per_s": f.clients[gt.NAME].limiter.rate,
        "errors": sum(1 for e in entries if e.error),
        "status": "COMPLETE" if meta["scheduler"]["replay_reserve_met"] else "INCOMPLETE_REPLAY",
    })
    raw.write_json("run.json", meta)
    return meta


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(prog="autopsyx.phase3c_acquire")
    ap.add_argument("--request", required=True)
    ap.add_argument("--out", required=True)
    ap.add_argument("--replay-reserve-s", type=int, default=DEFAULT_REPLAY_RESERVE_S)
    ap.add_argument("--enrichment-guard-s", type=int, default=DEFAULT_ENRICHMENT_GUARD_S)
    args = ap.parse_args(argv)
    req = json.load(open(args.request))
    plan = acquire.Plan(**{k: v for k, v in req.items() if k in acquire.Plan.__dataclass_fields__})
    reserve = int(req.get("phase3c1_replay_reserve_s", args.replay_reserve_s))
    guard = int(req.get("phase3c1_enrichment_guard_s", args.enrichment_guard_s))
    meta = run(args.out, plan, replay_reserve_s=reserve, enrichment_guard_s=guard)
    print(json.dumps({k: meta.get(k) for k in ("status", "cycles", "exchanges", "errors")}))
    return 0 if meta.get("status") == "COMPLETE" else 1


if __name__ == "__main__":
    raise SystemExit(main())
