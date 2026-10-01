"""Live acquisition run: select a universe, backfill, then poll in real time.

This is the only code in the repository that talks to vendor APIs, and it
only runs when invoked explicitly (``python -m autopsyx acquire --live``).
It never places orders and has no execution capability.

Because every response is stamped with the local receive time, records
collected here have *observed* availability times: during replay, a trade is
visible from the first poll that returned it, not from its block time.
"""
from __future__ import annotations

import logging
import os
import random
import time
from dataclasses import dataclass, field
from typing import Callable

from ..providers.base import ProviderError
from ..providers.http import CircuitBreaker, HttpClient, TokenBucket
from .providers import dexscreener as ds
from .providers import geckoterminal as gt
from .providers import news_social as ns
from .providers import solana_rpc as rpc
from .raw import ManifestEntry, RawStore

log = logging.getLogger("autopsyx.acquire")

# Base tokens that are not memecoins and are excluded from selection.
EXCLUDED_BASES = {
    "So11111111111111111111111111111111111111112",  # wrapped SOL
    "EPjFWdd5AufqSSqeM2qN1xzybapC8G4wEGGkZwyTDt1v",  # USDC
    "Es9vMFrzaCERmJfrF4H2FYD4KCoNkY11McCe8BenwNYB",  # USDT
}


@dataclass
class Plan:
    network: str = "solana"
    seed: int = 20260930
    strata: dict[str, int] = field(default_factory=lambda: {"young": 4, "quiet_young": 2, "trending": 3, "established": 3})
    new_pool_pages: int = 3
    backfill_pages: int = 2  # x 1000 minute bars per pool
    duration_s: int = 3600
    cycle_s: int = 60
    poll_ohlcv_limit: int = 5
    holders_per_cycle: int = 2
    lag_ms: int = 60_000
    gt_rate_per_s: float = 0.45  # below GeckoTerminal's published free-tier limit (30/min)
    ds_rate_per_s: float = 2.0
    gt_min_rate_per_s: float = 0.05  # adaptive floor after 429s
    ohlcv_every: int = 1  # poll OHLCV every N cycles
    circuit_waits: int = 3  # times a call waits out an open circuit before being recorded as failed
    rpc_rate_per_s: float = 2.0


class Fetcher:
    """Wraps provider clients; every exchange lands in the raw archive, errors included."""

    def __init__(self, raw: RawStore, clients: dict[str, HttpClient], now_ms: Callable[[], int],
                 sleep: Callable[[float], None] = time.sleep, circuit_waits: int = 0,
                 display: dict[str, str] | None = None):
        self.raw, self.clients, self.now_ms = raw, clients, now_ms
        # provider -> base URL written to the manifest in place of the real one
        # (a private RPC URL can embed a key; the archive must never hold it)
        self.display = display or {}
        self.sleep, self.circuit_waits = sleep, circuit_waits
        self.waited = 0

    def post(self, provider: str, endpoint: str, path: str, payload: dict,
             context: dict) -> tuple[ManifestEntry, bytes | None]:
        """JSON-RPC style POST; the request body is archived next to the response."""
        import json as _json
        return self.get(provider, endpoint, path, context, payload=_json.dumps(payload, sort_keys=True).encode())

    def get(self, provider: str, endpoint: str, path: str, context: dict,
            payload: bytes | None = None) -> tuple[ManifestEntry, bytes | None]:
        """One logical request. While the provider's circuit is open the call
        waits out the cooldown (up to ``circuit_waits`` times) instead of
        failing immediately; the first Phase 2 run lost its entire backfill
        because queued calls failed in milliseconds against an open circuit."""
        c = self.clients[provider]
        shown = self.display.get(provider, c.base_url)
        t0 = self.now_ms()
        waits = 0
        while True:
            try:
                r = c.get_raw(path) if payload is None else c._request(path, payload)
                break
            except ProviderError as exc:
                if "circuit open" in str(exc) and waits < self.circuit_waits:
                    waits += 1
                    self.waited += 1
                    self.sleep(c.breaker.cooldown_s)
                    continue
                err = exc
                r = None
                break
        if r is None:
            exc = err
            e = self.raw.record(provider=provider, endpoint=endpoint, url=shown + path, request_ts=t0,
                                response_ts=None, status=None, body=None, attempts=None, error=str(exc),
                                context=context | ({"circuit_waits": waits} if waits else {}),
                                attempt_log=getattr(exc, "attempt_log", ()), method="POST" if payload else "GET",
                                request_body=payload)
            return e, None
        e = self.raw.record(provider=provider, endpoint=endpoint, url=shown + r.url[len(c.base_url):], request_ts=r.request_ts,
                            response_ts=r.response_ts, status=r.status, body=r.body, attempts=r.attempts,
                            error=None, context=context, attempt_log=r.attempt_log,
                            method="POST" if payload else "GET", request_body=payload)
        return e, r.body


def collect_address_history(f: Fetcher, address: str, ctx: dict, *, page_limit: int = 100, max_pages: int = 3,
                            max_txs: int = 50, purpose: str = "funding") -> dict:
    """Signature index (paginated with ``before``) then each transaction, newest first.

    Bounded by ``max_pages`` x ``page_limit`` signatures and ``max_txs``
    transactions; whatever the bounds cut off is recorded in the returned
    summary (and so in run.json), never silently dropped. A failed page ends
    pagination and is recorded as a pagination gap.
    """
    sigs: list[dict] = []
    seen: set[str] = set()
    before, pages, truncated, gap = None, 0, False, None
    for page in range(max_pages):
        c = {**ctx, "address": address, "limit": page_limit, "page": page, "before": before, "purpose": purpose}
        e, b = f.post(rpc.NAME, "rpc.signatures", "", rpc.req_signatures(address, page_limit, before), c)
        pages += 1
        parsed = rpc.parse_signatures(e, b)
        if b is None or parsed.observations:  # transport or RPC failure
            gap = f"page {page} failed"
            f.raw.record(provider="audit", endpoint="pagination_gap", url=e.url, request_ts=e.request_ts,
                         response_ts=None, status=None, body=None, attempts=None,
                         error=f"signatures page {page} for {address} failed; older history not fetched",
                         context={"address": address, "page": page, "purpose": purpose})
            break
        for row in parsed.signatures:
            if row["signature"] not in seen:  # pages can overlap if the chain advanced between calls
                seen.add(row["signature"])
                sigs.append(row)
        before = parsed.next_before
        if before is None:
            break
    else:
        truncated = before is not None
    for row in sigs[:max_txs]:
        f.post(rpc.NAME, "rpc.transaction", "", rpc.req_transaction(row["signature"]),
               {**ctx, "address": address, "signature": row["signature"], "purpose": purpose})
    return {"address": address, "purpose": purpose, "pages": pages, "signatures": len(sigs),
            "transactions_requested": min(len(sigs), max_txs), "signatures_not_fetched": max(0, len(sigs) - max_txs),
            "history_truncated": truncated, "pagination_gap": gap}


def collect_news_social(f: Fetcher, token: str, symbol: str, ctx: dict) -> dict:
    """One GDELT and one Reddit search per token. A query GDELT cannot take
    (symbol under three characters) is recorded, not silently skipped."""
    done = {}
    q = ns.gdelt_query(symbol)
    if q is None:
        f.raw.record(provider="audit", endpoint="query_not_applicable", url="", request_ts=f.now_ms(), response_ts=None,
                     status=None, body=None, attempts=None, error=f"gdelt: symbol {symbol!r} shorter than 3 characters",
                     context={**ctx, "token": token, "provider": ns.GDELT})
        done["gdelt"] = "not_applicable"
    else:
        e, _ = f.get(ns.GDELT, "news.gdelt", ns.path_gdelt(q), {**ctx, "token": token, "query": q})
        done["gdelt"] = "error" if e.error else "ok"
    e, _ = f.get(ns.REDDIT, "social.reddit", ns.path_reddit(token), {**ctx, "token": token, "query": token})
    done["reddit"] = "error" if e.error else "ok"
    return done


def default_clients(plan: Plan, now_ms: Callable[[], int]) -> dict[str, HttpClient]:
    return {
        gt.NAME: HttpClient(gt.BASE, TokenBucket(plan.gt_rate_per_s, 2), dict(gt.HEADERS), max_retries=3,
                            timeout_s=15, backoff_s=2.0, breaker=CircuitBreaker(8, 90), now_ms=now_ms,
                            adaptive_min_rate=plan.gt_min_rate_per_s, adaptive_step=0.005),
        ds.NAME: HttpClient(ds.BASE, TokenBucket(plan.ds_rate_per_s, 4), dict(ds.HEADERS), max_retries=3,
                            timeout_s=15, backoff_s=2.0, breaker=CircuitBreaker(8, 90), now_ms=now_ms),
        # Phase 3A sources. Rates sit below each service's documented public guidance
        # (GDELT: one request per 5 s; public Solana RPC: well under its per-IP limit).
        rpc.NAME: HttpClient(rpc.BASE, TokenBucket(plan.rpc_rate_per_s, 2), dict(rpc.HEADERS), max_retries=3,
                             timeout_s=20, backoff_s=2.0, breaker=CircuitBreaker(8, 90), now_ms=now_ms,
                             adaptive_min_rate=0.2, adaptive_step=0.02),
        ns.GDELT: HttpClient(ns.GDELT_BASE, TokenBucket(0.18, 1), dict(ns.HEADERS), max_retries=2,
                             timeout_s=20, backoff_s=6.0, breaker=CircuitBreaker(6, 120), now_ms=now_ms),
        ns.REDDIT: HttpClient(ns.REDDIT_BASE, TokenBucket(0.15, 1), dict(ns.HEADERS), max_retries=2,
                              timeout_s=15, backoff_s=6.0, breaker=CircuitBreaker(6, 120), now_ms=now_ms),
    }


def _pools_from(e: ManifestEntry, body: bytes | None) -> list[dict]:
    if body is None:
        return []
    parsed = gt.parse_pools(e, body)
    infos = [r for r in parsed.records if type(r).__name__ == "PoolInfo"]
    snaps = {r.pool: r for r in parsed.records if type(r).__name__ == "PoolSnapshot"}
    metas = {r.ref.address: r for r in parsed.records if type(r).__name__ == "TokenMeta"}
    out = []
    import json as _json
    tx = {}
    try:
        for item in _json.loads(body.decode()).get("data", []):
            tx[item["attributes"]["address"]] = item["attributes"].get("transactions", {}).get("h1", {})
    except (ValueError, KeyError, TypeError, AttributeError):
        pass
    for p in infos:
        s = snaps.get(p.pool)
        h1 = tx.get(p.pool, {})
        out.append({"pool": p.pool, "token": p.token, "dex": p.venue, "created_ts": p.created_ts,
                    "liquidity_usd": s.liquidity_usd if s else None,
                    "h1_txns": (h1.get("buys") or 0) + (h1.get("sells") or 0) if isinstance(h1, dict) else None,
                    "total_supply": metas[p.token].total_supply if p.token in metas else None})
    return out


def select_universe(f: Fetcher, plan: Plan) -> dict:
    """Stratified random selection, recorded in full so it can be audited.

    Strata (evaluated on data available at selection time only):
      young        random pools from the newest-pools pages
      quiet_young  newest pools with fewer than 5 txns in the last hour
      trending     random pools from GeckoTerminal's trending list
      established  random pools from the top-24h-volume list
    Tokens already picked in an earlier stratum are skipped, and non-meme
    base assets (SOL, USDC, USDT) are excluded.
    """
    n = plan.network
    cands: dict[str, list[dict]] = {"young": [], "trending": [], "established": []}
    for page in range(1, plan.new_pool_pages + 1):
        e, b = f.get(gt.NAME, "gt.new_pools", gt.path_new_pools(n, page), {"chain": n, "stratum": "young", "page": page})
        if b is None:
            f.raw.record(provider="audit", endpoint="pagination_gap", url=e.url, request_ts=e.request_ts,
                         response_ts=None, status=None, body=None, attempts=None,
                         error=f"new_pools page {page} failed; later pages still fetched", context={"page": page})
        cands["young"] += _pools_from(e, b)
    e, b = f.get(gt.NAME, "gt.trending", gt.path_trending(n), {"chain": n, "stratum": "trending"})
    cands["trending"] = _pools_from(e, b)
    e, b = f.get(gt.NAME, "gt.top_pools", gt.path_top_pools(n), {"chain": n, "stratum": "established"})
    cands["established"] = _pools_from(e, b)

    rng = random.Random(plan.seed)
    picked: list[dict] = []
    tokens: set[str] = set()
    excluded: list[dict] = []

    def take(stratum: str, pool_list: list[dict], k: int) -> None:
        pool_list = sorted(pool_list, key=lambda p: p["pool"])  # order-independent sampling
        rng.shuffle(pool_list)
        for p in pool_list:
            if len([x for x in picked if x["stratum"] == stratum]) >= k:
                return
            if p["token"] in EXCLUDED_BASES:
                excluded.append({**p, "reason": "non-meme base asset"})
                continue
            if p["token"] in tokens:
                continue
            picked.append({**p, "stratum": stratum})
            tokens.add(p["token"])

    quiet = [p for p in cands["young"] if p["h1_txns"] is not None and p["h1_txns"] < 5]
    take("quiet_young", quiet, plan.strata["quiet_young"])
    take("young", cands["young"], plan.strata["young"])
    take("trending", cands["trending"], plan.strata["trending"])
    take("established", cands["established"], plan.strata["established"])
    sel = {"seed": plan.seed, "strata_targets": plan.strata, "selected_at_ms": f.now_ms(),
           "candidates": {k: len(v) for k, v in cands.items()} | {"quiet_young": len(quiet)},
           "picked": picked, "excluded": excluded,
           "procedure": select_universe.__doc__}
    f.raw.write_json("selection.json", sel)
    return sel


def backfill(f: Fetcher, plan: Plan, picked: list[dict]) -> None:
    n = plan.network
    for p in picked:
        ctx = {"chain": n, "pool": p["pool"], "token": p["token"]}
        before = None
        for page in range(plan.backfill_pages):
            e, b = f.get(gt.NAME, "gt.ohlcv", gt.path_ohlcv(n, p["pool"], 1000, before), {**ctx, "page": page})
            if b is None:
                break
            bars = [r for r in gt.parse_ohlcv(e, b, plan.lag_ms).records if type(r).__name__ == "ProviderBar"]
            if len(bars) < 900:
                break  # reached the start of the pool's history
            before = min(x.ts for x in bars) // 1000
        f.get(gt.NAME, "gt.token_info", gt.path_token_info(n, p["token"]),
              {**ctx, "pool_created_ts": p["created_ts"], "total_supply": p["total_supply"]})


def poll_cycle(f: Fetcher, plan: Plan, picked: list[dict], cycle: int) -> None:
    n = plan.network
    pools = [p["pool"] for p in picked]
    for i in range(0, len(pools), 30):
        chunk = pools[i:i + 30]
        f.get(gt.NAME, "gt.pools_multi", gt.path_pools_multi(n, chunk), {"chain": n, "cycle": cycle})
    for i in range(0, len(picked), ds.MAX_PAIRS_PER_CALL):
        chunk = picked[i:i + ds.MAX_PAIRS_PER_CALL]
        f.get(ds.NAME, "ds.pairs", ds.path_pairs(n, [p["pool"] for p in chunk]),
              {"chain": n, "cycle": cycle, "pool_tokens": {p["pool"]: p["token"] for p in chunk}})
    for p in picked:
        ctx = {"chain": n, "pool": p["pool"], "token": p["token"], "cycle": cycle}
        f.get(gt.NAME, "gt.trades", gt.path_trades(n, p["pool"]), ctx)
        if cycle % plan.ohlcv_every == 0:
            f.get(gt.NAME, "gt.ohlcv", gt.path_ohlcv(n, p["pool"], plan.poll_ohlcv_limit), ctx)
    for k in range(plan.holders_per_cycle):
        p = picked[(cycle * plan.holders_per_cycle + k) % len(picked)]
        f.get(gt.NAME, "gt.token_info", gt.path_token_info(n, p["token"]),
              {"chain": n, "pool": p["pool"], "token": p["token"], "cycle": cycle,
               "pool_created_ts": p["created_ts"], "total_supply": p["total_supply"]})


def run(run_dir: str, plan: Plan, clients: dict[str, HttpClient] | None = None,
        now_ms: Callable[[], int] = lambda: int(time.time() * 1000),
        sleep: Callable[[float], None] = time.sleep, max_cycles: int | None = None) -> dict:
    raw = RawStore(run_dir)
    f = Fetcher(raw, clients or default_clients(plan, now_ms), now_ms, sleep, plan.circuit_waits)
    started = now_ms()
    meta = {"started_ms": started, "plan": plan.__dict__, "code_version": os.environ.get("GITHUB_SHA", "local"),
            "runner": os.environ.get("RUNNER_NAME", "local"), "execution": "none: acquisition only, no orders"}
    raw.write_json("run.json", meta)
    sel = select_universe(f, plan)
    if not sel["picked"]:
        meta["status"] = "BLOCKED: no pools selectable (discovery failed)"
        raw.write_json("run.json", meta)
        return meta
    backfill(f, plan, sel["picked"])
    cycle = 0
    while True:
        t0 = now_ms()
        if (t0 - started) / 1000 >= plan.duration_s or (max_cycles is not None and cycle >= max_cycles):
            break
        poll_cycle(f, plan, sel["picked"], cycle)
        cycle += 1
        spent = (now_ms() - t0) / 1000
        if spent < plan.cycle_s:
            sleep(plan.cycle_s - spent)
    entries = raw.entries()
    meta.update({"ended_ms": now_ms(), "cycles": cycle, "exchanges": len(entries), "circuit_waits": f.waited,
                 "final_gt_rate_per_s": f.clients[gt.NAME].limiter.rate,
                 "errors": sum(1 for e in entries if e.error), "status": "COMPLETE"})
    raw.write_json("run.json", meta)
    log.info("acquisition done", extra={"fields": {k: meta[k] for k in ("cycles", "exchanges", "errors")}})
    return meta
