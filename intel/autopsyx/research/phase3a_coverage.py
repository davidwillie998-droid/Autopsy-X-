"""Machine-readable coverage matrix (evidence layer).

One row per (archive, token in the archive's frozen universe or selection).
Every cell is a dict with a ``state`` from the dimension's declared
vocabulary, the counts behind it, and a reason when the state is not the
positive one. No cell is ever blank: a fact that was not sought is
UNAVAILABLE (source not in the archive's plan) or UNKNOWN (source present,
this token never asked), never zero.
"""
from __future__ import annotations

import dataclasses
from collections import Counter, defaultdict
from pathlib import Path

from ..core.observation import Availability as A
from ..core.observation import ContractViolation, Observation, dedupe, validate
from ..data.normalize3a import PARSERS
from ..data.providers import geckoterminal as gt
from ..data.raw import RawStore
from ..providers.store import EventStore
from . import phase3a_telemetry as tel

DIMENSIONS = ("archive", "token", "funding_transfer", "liquidity_events", "creator_state", "holder_state", "news",
              "social", "ohlcv", "trades", "freshness", "provider", "replayability", "point_in_time_validity")
OBS_DIMS = {"funding_transfer": "funding_transfer", "liquidity_events": "liquidity_event",
            "creator_state": "creator_state", "holder_state": "holder_state", "news": "news", "social": "social"}
DATA_STATES = [a.value for a in A]
VOCABULARY = {
    **{d: DATA_STATES for d in OBS_DIMS},
    "ohlcv": DATA_STATES, "trades": DATA_STATES,
    "freshness": ["OBSERVED", "STALE", "NOT_OBSERVED"],
    "provider": ["OBSERVED", "ERROR", "NOT_OBSERVED"],
    "replayability": ["VERIFIED", "FAILED", "NOT_REPLAYABLE"],
    "point_in_time_validity": ["VERIFIED", "FAILED"],
    "archive": ["IDENTITY"], "token": ["IDENTITY"],
}
STATE_RULE = ("OBSERVED if any OBSERVED record; else NOT_OBSERVED if any; else NOT_APPLICABLE if the question was "
              "not applicable; else ERROR if any; else UNKNOWN if the archive's plan included the source but this token "
              "was never asked; else UNAVAILABLE (source not in the archive's acquisition plan)")
SOURCE_ENDPOINTS = {
    "funding_transfer": lambda e: e.endpoint.startswith("rpc.") and (e.context or {}).get("purpose") == "funding",
    "liquidity_event": lambda e: (e.endpoint.startswith("rpc.") and (e.context or {}).get("purpose") == "liquidity")
    or e.endpoint in ("gt.new_pools", "gt.trending", "gt.top_pools", "gt.pools_multi"),
    "creator_state": lambda e: e.endpoint == "gt.token_info",
    "holder_state": lambda e: e.endpoint == "gt.token_info",
    "news": lambda e: e.endpoint == "news.gdelt" or (e.endpoint == "query_not_applicable" and (e.context or {}).get("provider") == "gdelt"),
    "social": lambda e: e.endpoint == "social.reddit",
}


def universe(raw: RawStore) -> tuple[str, list[dict]]:
    u = raw.read_json("universe.json")
    if u:
        return "universe.json", sorted(u["pools"], key=lambda p: p["token"])
    sel = raw.read_json("selection.json") or {"picked": []}
    return "selection.json", sorted(({"pool": p["pool"], "token": p["token"]} for p in sel["picked"]),
                                    key=lambda p: p["token"])


def observations_by_token(raw: RawStore, tokens: set[str]) -> dict[str, list[Observation]]:
    """Run the Phase 3A parsers entry by entry so each observation keeps the
    token its request was made for (funding observations are about a wallet;
    pool-creation observations name their base mint)."""
    out: dict[str, list[Observation]] = defaultdict(list)
    for e in raw.entries():
        parse = PARSERS.get(e.endpoint)
        if parse is None:
            continue
        p = parse(e, raw.body(e.raw_id) if e.raw_id else None)
        for o in p.observations:
            t = (e.context or {}).get("token") or o.value.get("base_mint")
            if t in tokens:
                out[t].append(o)
    return {t: dedupe(v)[0] for t, v in out.items()}


def _obs_cell(obs: list[Observation], asked: bool, plan_has_source: bool, na: bool) -> dict:
    c = Counter(o.state.value for o in obs)
    counts = {s: c.get(s, 0) for s in DATA_STATES}
    if c.get("OBSERVED"):
        state, reason = "OBSERVED", ""
    elif c.get("NOT_OBSERVED"):
        state, reason = "NOT_OBSERVED", "provider answered without the fact"
    elif na:
        state, reason = "NOT_APPLICABLE", "query not applicable for this token (recorded in the manifest)"
    elif c.get("ERROR"):
        state, reason = "ERROR", "every request for this token failed"
    elif plan_has_source and not asked:
        state, reason = "UNKNOWN", "source in the archive's plan, but never asked for this token"
    elif plan_has_source:
        state, reason = "UNKNOWN", "asked, but no observation could be derived"
    else:
        state, reason = "UNAVAILABLE", "source not in this archive's acquisition plan"
    return {"state": state, "counts": counts, "records": len(obs), "reason": reason}


def _market_cell(pairs, token: str, endpoint: str, parse, rec_type: str) -> dict:
    """pairs: (manifest entry, body) for market endpoints."""
    es = [(e, b) for e, b in pairs if e.endpoint == endpoint and (e.context or {}).get("token") == token]
    ok = [(e, b) for e, b in es if e.error is None and b is not None]
    n = 0
    for e, body in ok:
        n += sum(1 for r in parse(e, body).records if type(r).__name__ == rec_type)
    if n:
        state, reason = "OBSERVED", ""
    elif ok:
        state, reason = "NOT_OBSERVED", "responses arrived without records"
    elif es:
        state, reason = "ERROR", "every request failed"
    else:
        state, reason = "UNKNOWN", "never requested for this token"
    return {"state": state, "requests": len(es), "successful": len(ok), "records": n, "reason": reason}


def _pit_check(obs: list[Observation]) -> tuple[bool, list[str]]:
    """Each observation satisfies the contract, is invisible one millisecond
    before ingestion and visible at ingestion; a future copy of every record
    leaves every earlier view unchanged."""
    bad = []
    for o in obs:
        try:
            validate(o)
        except ContractViolation as exc:
            bad.append(f"contract: {exc}")
    s = EventStore()
    s.extend(obs)
    kinds = sorted({o.kind for o in obs})
    for o in obs:
        if o in s.view(o.ingestion_ts - 1).observations(o.kind):
            bad.append(f"visible before ingestion: {o.kind} {o.signature or o.entity}")
        if o not in s.view(o.ingestion_ts).observations(o.kind):
            bad.append(f"invisible at ingestion: {o.kind} {o.signature or o.entity}")
    if obs:
        cut = sorted(o.ingestion_ts for o in obs)[len(obs) // 2]
        before = {k: s.view(cut).observations(k) for k in kinds}
        s.extend(dataclasses.replace(o, ingestion_ts=cut + 1 + i, observation_ts=min(o.observation_ts, cut))
                 for i, o in enumerate(obs))
        if any(s.view(cut).observations(k) != before[k] for k in kinds):
            bad.append("a future observation changed an earlier view")
    return not bad, bad


def matrix(archives: list[Path], replay: dict[str, dict], cfg) -> dict:
    """``replay`` maps archive id -> {"replayable", "identical", "lookahead_all_passed", "observations_identical"}."""
    policy = tel.freshness_policy(cfg)
    rows = []
    for d in archives:
        raw = RawStore(d)
        entries = raw.entries()
        src, pools = universe(raw)
        tokens = {p["token"] for p in pools}
        by_tok = observations_by_token(raw, tokens)
        plan_sources = {k: any(f(e) for e in entries) for k, f in SOURCE_ENDPOINTS.items()}
        bodies = {e.seq: raw.body(e.raw_id) if e.raw_id else None for e in entries
                  if e.endpoint in ("gt.ohlcv", "gt.trades")}
        market = [(e, bodies.get(e.seq)) for e in entries if e.endpoint in ("gt.ohlcv", "gt.trades")]
        rp = replay.get(d.name, {})
        lag = ((raw.read_json("run.json") or {}).get("plan") or {}).get("lag_ms", 60_000)
        for p in pools:
            t = p["token"]
            obs = by_tok.get(t, [])
            row = {"archive": {"state": "IDENTITY", "value": d.name, "universe_source": src},
                   "token": {"state": "IDENTITY", "value": t, "pool": p["pool"]}}
            for dim, kind in OBS_DIMS.items():
                ko = [o for o in obs if o.kind == kind]
                asked = any(SOURCE_ENDPOINTS[kind](e) and (e.context or {}).get("token") == t for e in entries)
                na = any(e.endpoint == "query_not_applicable" and (e.context or {}).get("token") == t
                         and kind == "news" for e in entries)
                cell = _obs_cell(ko, asked, plan_sources[kind], na)
                if kind == "liquidity_event":
                    cell["vault_delta_requests"] = sum(1 for e in entries if e.endpoint == "rpc.transaction"
                                                       and (e.context or {}).get("purpose") == "liquidity"
                                                       and (e.context or {}).get("token") == t)
                    m = Counter((o.value.get("classification_method"), o.value.get("event_type")) for o in ko
                                if o.state == A.OBSERVED)
                    cell["by_method_and_type"] = {f"{a}|{b}": n for (a, b), n in sorted(m.items())}
                if kind == "funding_transfer":
                    st = Counter(o.value.get("tx_status") for o in ko if o.state == A.OBSERVED)
                    cell["observed_by_tx_status"] = dict(sorted(st.items()))
                row[dim] = cell
            row["ohlcv"] = _market_cell(market, t, "gt.ohlcv",
                                        lambda e, b: gt.parse_ohlcv(e, b, lag), "ProviderBar")
            row["trades"] = _market_cell(market, t, "gt.trades",
                                         lambda e, b: gt.parse_trades(e, b, lag), "Swap")
            mine = [e for e in entries if (e.context or {}).get("token") == t]
            fr = tel.freshness(mine, policy)
            if fr["governed_evaluations"] == 0:
                row["freshness"] = {"state": "NOT_OBSERVED", "evaluations": 0, "stale": 0,
                                    "reason": "no repeated market polls for this token"}
            else:
                row["freshness"] = {"state": "STALE" if fr["governed_stale"] else "OBSERVED",
                                    "evaluations": fr["governed_evaluations"], "stale": fr["governed_stale"],
                                    "compliance": fr["governed_compliance"],
                                    "reason": "" if not fr["governed_stale"] else f"age above {policy['max_age_ms']} ms"}
            errs = sum(1 for e in mine if e.error)
            row["provider"] = {"state": "NOT_OBSERVED" if not mine else ("ERROR" if errs else "OBSERVED"),
                               "requests": len(mine), "errors": errs,
                               "reason": "" if mine and not errs else ("no requests" if not mine else "some requests failed")}
            if not rp.get("replayable"):
                rstate, rreason = "NOT_REPLAYABLE", rp.get("reason", "no live poll window in archive")
            elif rp.get("identical") and rp.get("observations_identical"):
                rstate, rreason = "VERIFIED", ""
            else:
                rstate, rreason = "FAILED", "two replays or two normalizations differed"
            row["replayability"] = {"state": rstate, "reason": rreason}
            ok, why = _pit_check(obs)
            la = rp.get("lookahead_all_passed")
            pit_ok = ok and la is not False
            row["point_in_time_validity"] = {
                "state": "VERIFIED" if pit_ok else "FAILED", "observation_checks": len(obs),
                "archive_lookahead_audit": "PASSED" if la else ("NOT_RUN (archive not replayable)" if la is None else "FAILED"),
                "reason": "; ".join(why[:3]) if why else ("" if pit_ok else "archive look-ahead audit failed")}
            rows.append(row)
    blanks = [(i, d) for i, r in enumerate(rows) for d in DIMENSIONS if not r.get(d) or not r[d].get("state")]
    totals = totals_of(rows)
    return {"dimensions": list(DIMENSIONS), "vocabulary": VOCABULARY, "state_rule": STATE_RULE,
            "freshness_policy_fingerprint": tel.policy_fingerprint(policy),
            "rows": rows, "row_count": len(rows), "blank_cells": len(blanks), "totals": totals}


def totals_of(rows: list[dict]) -> dict:
    """Per-dimension state counts and positive share over a set of matrix rows."""
    totals = {}
    for d in DIMENSIONS[2:]:
        c = Counter(r[d]["state"] for r in rows)
        totals[d] = {s: c.get(s, 0) for s in VOCABULARY[d]}
        pos = "VERIFIED" if d in ("replayability", "point_in_time_validity") else "OBSERVED"
        totals[d]["positive_state"] = pos
        totals[d]["positive_share"] = round(c.get(pos, 0) / len(rows), 6) if rows else None
    # Pool-creation metadata alone says nothing about later adds or removes; count
    # rows where the chain-derived (vault delta) method observed anything at all.
    vd = sum(1 for r in rows if any(k.startswith("vault_balance_delta|")
                                    for k in r["liquidity_events"].get("by_method_and_type", {})))
    vd_asked = sum(1 for r in rows if r["liquidity_events"].get("vault_delta_requests", 0))
    totals["liquidity_events"]["rows_with_vault_delta_events"] = vd
    totals["liquidity_events"]["rows_with_vault_delta_requests"] = vd_asked
    totals["liquidity_events"]["vault_delta_share"] = round(vd / len(rows), 6) if rows else None
    return totals
