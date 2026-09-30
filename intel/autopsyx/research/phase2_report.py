"""Numbers for docs/PHASE2_REAL_DATA_REPLAY_REPORT.md, computed from a run
directory's archive, normalization report and replay journal. Descriptive
only: nothing here scores or ranks strategy performance."""
from __future__ import annotations

import json
from collections import Counter, defaultdict
from pathlib import Path

from ..data.normalize import normalize
from ..data.raw import RawStore
from .early_life import evaluate as early_life


def build(run_dir: str, replay_dir: str, min_coverage: float) -> dict:
    raw = RawStore(run_dir)
    entries = raw.entries()
    records, rep = normalize(run_dir)
    journal = [json.loads(l)["payload"] for l in Path(replay_dir, "journal.jsonl").read_text().splitlines() if l]
    summary = json.loads(Path(replay_dir, "summary.json").read_text())

    by_ep = defaultdict(lambda: {"calls": 0, "ok": 0, "errors": 0, "retried": 0, "latency_ms": []})
    for e in entries:
        d = by_ep[f"{e.provider}:{e.endpoint}"]
        d["calls"] += 1
        if e.error:
            d["errors"] += 1
        else:
            d["ok"] += 1
            d["latency_ms"].append(e.response_ts - e.request_ts)
        if (e.attempts or 1) > 1:
            d["retried"] += 1
    endpoints = {}
    for k, d in sorted(by_ep.items()):
        lat = sorted(d.pop("latency_ms"))
        d["p50_latency_ms"] = lat[len(lat) // 2] if lat else None
        d["p95_latency_ms"] = lat[int(len(lat) * 0.95) - 1] if len(lat) >= 20 else (lat[-1] if lat else None)
        endpoints[k] = d
    errors = Counter((e.error or "").split(":")[0][:80] for e in entries if e.error)

    # Availability lag of trades: seen_ts - ts for the first sighting of each swap.
    first_seen: dict = {}
    for r in records:
        if type(r).__name__ == "Swap":
            if r.uid not in first_seen or r.seen_ts < first_seen[r.uid][0]:
                first_seen[r.uid] = (r.seen_ts, r.ts)
    lags = sorted(s - t for s, t in first_seen.values())
    live_lags = sorted(l for l in lags if l < 30 * 60_000)  # excludes history returned by the first poll

    status = defaultdict(Counter)
    for r in journal:
        for f, st in r["feature_status"].items():
            status[f][st] += 1
    missingness = {f: {k: v / sum(c.values()) for k, v in sorted(c.items())} for f, c in sorted(status.items())}

    blocked = Counter(b for r in journal for b in r["blocked_by"])
    per_token = defaultdict(lambda: Counter())
    for r in journal:
        per_token[r["token"]][r["move_class"]] += 1
    sel = raw.read_json("selection.json") or {}
    return {
        "run": raw.read_json("run.json"), "selection": {k: sel.get(k) for k in ("seed", "strata_targets", "candidates")},
        "picked": sel.get("picked"), "excluded": sel.get("excluded"),
        "normalization": {k: v for k, v in rep.to_dict().items() if k != "issue_samples"},
        "issue_samples": rep.issue_samples, "endpoints": endpoints, "error_kinds": dict(errors),
        "unique_swaps": len(first_seen),
        "trade_availability_lag_ms": {"p50": live_lags[len(live_lags) // 2] if live_lags else None,
                                      "p95": live_lags[int(len(live_lags) * 0.95) - 1] if len(live_lags) >= 20 else None,
                                      "n": len(live_lags)},
        "replay_summary": summary, "missingness": missingness, "blocked_by": dict(blocked.most_common()),
        "move_class_by_token": {k: dict(v) for k, v in sorted(per_token.items())},
        "early_life": early_life(journal, min_coverage),
    }
