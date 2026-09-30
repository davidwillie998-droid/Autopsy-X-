"""Numbers for docs/PHASE2_REPORT.md, computed from a run
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
    from ..data.normalize import restrict_to_selection
    records = restrict_to_selection(records, raw.read_json("selection.json"))  # the polled universe
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
        "raw_audit": raw_audit(run_dir), "field_coverage": field_coverage(records, journal),
        "journal_audit": journal_audit(replay_dir), "decisions": decision_distribution(journal),
    }


# ---------------------------------------------------------------------------------------------
# Final-gate audits. Every number is computed from the archive, the normalized records or the
# journal; nothing is typed by hand.
import gzip
import hashlib


def raw_audit(run_dir: str) -> dict:
    """Per-provider integrity counts over the raw archive."""
    raw = RawStore(run_dir)
    entries = raw.entries()
    out: dict[str, Counter] = defaultdict(Counter)
    seen_ids: Counter = Counter()
    last_resp = None
    for e in entries:
        c = out[e.provider]
        c["exchanges"] += 1
        if e.request_ts is None:
            c["missing_request_ts"] += 1
        if e.error:
            c["provider_errors"] += 1
            continue
        if e.response_ts is None:
            c["missing_response_ts"] += 1
            continue
        if e.response_ts < e.request_ts:
            c["response_before_request"] += 1
        if last_resp is not None and e.response_ts < last_resp:
            c["out_of_order_response"] += 1
        last_resp = e.response_ts if last_resp is None else max(last_resp, e.response_ts)
        if e.status != 200:
            c["non_200"] += 1
        p = Path(run_dir, "raw", f"{e.raw_id}.json.gz")
        if not p.exists():
            c["missing_body_file"] += 1
            continue
        body = gzip.decompress(p.read_bytes())
        if hashlib.sha256(body).hexdigest() != e.raw_id:
            c["hash_mismatch"] += 1
            continue
        if len(body) != e.bytes:
            c["length_mismatch"] += 1
        if not body.strip():
            c["empty_body"] += 1
            continue
        seen_ids[e.raw_id] += 1
        if seen_ids[e.raw_id] > 1:
            c["identical_body_repeats"] += 1  # same bytes returned again (quiet pool, unchanged state)
        try:
            doc = json.loads(body)
            c["valid_json"] += 1
        except ValueError:
            c["malformed_json"] += 1
            continue
        if isinstance(doc, dict) and ("errors" in doc or ("data" not in doc and "pairs" not in doc)):
            c["partial_or_error_body"] += 1
    files = {p.name[:-8] for p in Path(run_dir, "raw").glob("*.json.gz")}
    referenced = {e.raw_id for e in entries if e.raw_id}
    return {"by_provider": {k: dict(v) for k, v in sorted(out.items())},
            "body_files": len(files), "referenced_bodies": len(referenced),
            "unreferenced_body_files": len(files - referenced), "referenced_but_missing": len(referenced - files)}


def field_coverage(records: list, journal: list[dict]) -> dict:
    """Measured presence of each capability in the actual dataset."""
    tok = {r.ref.key for r in records if type(r).__name__ == "TokenMeta"}
    by: dict[str, set] = defaultdict(set)
    n = Counter()
    for r in records:
        t = type(r).__name__
        n[t] += 1
        key = f"{getattr(r, 'chain', '')}:{getattr(r, 'token', '')}" if hasattr(r, "token") else r.ref.key if t == "TokenMeta" else None
        if key:
            by[t].add(key)
    cov_trades = [r for r in records if type(r).__name__ == "Coverage" and r.kind == "trades"]
    creator_ids = sum(1 for r in records if type(r).__name__ == "TokenMeta" and r.creator)
    creator_pct = sum(1 for r in records if type(r).__name__ == "HolderSnapshot" and r.creator_pct is not None)
    holders = n["HolderSnapshot"]
    fs = Counter()
    for j in journal:
        for f, st in j["feature_status"].items():
            fs[(f, st == "OK")] += 1
    steps = len(journal) or 1
    ok_share = lambda f: fs[(f, True)] / steps
    wallets = {r.wallet for r in records if type(r).__name__ == "Swap"}
    return {
        "tokens": len(tok),
        "rows": {
            "OHLCV": {"records": n["ProviderBar"], "tokens_with": len(by["ProviderBar"]), "pit_ok_share": ok_share("price_z_driving")},
            "trades": {"records": n["Swap"], "tokens_with": len(by["Swap"]), "coverage_claims": len(cov_trades),
                       "full_page_claims": None, "pit_ok_share": ok_share("unique_buyers")},
            "wallet address": {"distinct_wallets": len(wallets), "tokens_with": len(by["Swap"]),
                               "pit_ok_share": ok_share("unique_buyers")},
            "liquidity": {"records": n["PoolSnapshot"], "tokens_with": len(by["PoolSnapshot"]),
                          "pit_ok_share": ok_share("liquidity_usd")},
            "liquidity changes": {"lp_events": n["LiquidityEvent"], "pit_ok_share": ok_share("liquidity_change")},
            "creator holdings": {"holder_snapshots": holders, "with_creator_pct": creator_pct,
                                 "tokens_with_creator_identity": creator_ids, "pit_ok_share": ok_share("creator_pct")},
            "holder concentration": {"holder_snapshots": holders, "tokens_with": len(by["HolderSnapshot"]),
                                     "pit_ok_share": ok_share("top10_pct")},
            "funding transfers": {"records": n["FundingTransfer"]},
            "social": {"records": n["SocialPost"], "pit_ok_share": ok_share("social_mentions")},
            "news": {"records": n["NewsEvent"]},
        },
    }


def journal_audit(replay_dir: str) -> dict:
    lines = [l for l in Path(replay_dir, "journal.jsonl").read_text().splitlines() if l.strip()]
    prev, breaks, bad_hash, configs, dup = "genesis", 0, 0, set(), 0
    keys, order_violations, last_t = set(), 0, None
    for l in lines:
        rec = json.loads(l)
        h = rec.pop("hash")
        if rec["prev"] != prev:
            breaks += 1
        if hashlib.sha256(json.dumps(rec, sort_keys=True, default=str).encode()).hexdigest() != h:
            bad_hash += 1
        configs.add(rec["config"])
        p = rec["payload"]
        k = (p["token"], p["as_of"])
        dup += k in keys
        keys.add(k)
        if last_t is not None and p["as_of"] < last_t:
            order_violations += 1
        last_t = p["as_of"]
        if p["configuration_hash"] != rec["config"]:
            configs.add("MISMATCH")
        prev = h
    return {"entries": len(lines), "chain_breaks": breaks, "hash_mismatches": bad_hash,
            "configuration_hashes": sorted(configs), "duplicate_token_steps": dup,
            "chronology_violations": order_violations, "head_hash": prev}


REASON_CATEGORIES = [
    ("creator_concentration_unavailable", lambda b: "critical input missing: creator_concentration_ok" in b),
    ("manipulation_input_unavailable", lambda b: "critical input missing: low_manipulation" in b),
    ("execution_liquidity_unavailable", lambda b: "critical input missing: execution_liquidity" in b),
    ("low_liquidity", lambda b: b == "LOW_LIQUIDITY" or b.startswith("veto: execution_liquidity")),
    ("stale_data", lambda b: b == "STALE_DATA"),
    ("conflicting_data", lambda b: b == "CONFLICTING_DATA"),
    ("no_data", lambda b: b == "NO_DATA"),
    ("manipulation_veto", lambda b: b.startswith("veto: low_manipulation")),
    ("creator_concentration_veto", lambda b: b.startswith("veto: creator_concentration_ok")),
    ("structure_veto", lambda b: b.startswith("veto: healthy_structure")),
    ("follower_veto", lambda b: "follower_independent_confirmation" in b),
    ("insufficient_coverage", lambda b: b.startswith("coverage ")),
]


def decision_distribution(journal: list[dict]) -> dict:
    total = len(journal)
    sig = Counter(j["signal"] for j in journal)
    reasons = Counter()
    for j in journal:
        for b in j["blocked_by"]:
            cat = next((name for name, f in REASON_CATEGORIES if f(b)), "other")
            reasons[cat] += 1
    blocked = sum(1 for j in journal if j["blocked_by"])
    no_sig_unblocked = sum(1 for j in journal if j["signal"] == "NO_SIGNAL" and not j["blocked_by"])
    return {
        "total_replay_assessments": total,
        "HIGH_CONVICTION_CONTINUATION": sig["HIGH_CONVICTION_CONTINUATION"], "WATCH": sig["WATCH"],
        "NO_SIGNAL": sig["NO_SIGNAL"],
        "blocked": blocked,
        "no_signal_without_block_reason": no_sig_unblocked,  # no qualifying move: nothing to gate
        "unclassified": sum(1 for j in journal if j["move_class"] == "UNCLASSIFIED"),
        "risk_rejected": sum(1 for j in journal if j["risk"] and not j["risk"]["approved"]),
        "data_quality_rejected": sum(1 for j in journal if any(b in ("NO_DATA", "STALE_DATA", "CONFLICTING_DATA",
                                     "API_FAILURE", "EXECUTION_UNAVAILABLE", "LOW_LIQUIDITY") for b in j["blocked_by"])),
        "manipulation_vetoed": sum(1 for j in journal if any(b.startswith("veto: low_manipulation") for b in j["blocked_by"])),
        "hypothetical_entries": sum(1 for j in journal if j["entry"]),
        "emergency_exits": sum(1 for j in journal if (j["exit"] or {}).get("action") == "EMERGENCY_EXIT"),
        "block_reason_occurrences": dict(reasons.most_common()),
        "assessments_blocked_by_creator_gate_alone": sum(
            1 for j in journal if j["blocked_by"] == ["critical input missing: creator_concentration_ok"]),
    }
