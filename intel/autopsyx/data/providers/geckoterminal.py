"""GeckoTerminal public API adapter (api.geckoterminal.com/api/v2, no key).

What this source provides, as observed in Phase 2 probes:
  pools (lists, multi)  price, reserve_in_usd, fdv, pool_created_at, dex id,
                        aggregate txn and buyer counts (NOT per-wallet)
  pool trades           the latest <= 300 trades of the last 24 h, each with
                        block, block time (1 s resolution), tx hash, signer
                        (tx_from_address), side, amounts, USD volume
  pool OHLCV            minute bars with USD volume; minutes without trades
                        are omitted; the in-progress minute is included
  token info            symbol, name, holder count, top-10 share, developer
                        address/holding (usually null)
What it does not provide: funding transfers, liquidity add/remove events,
historical liquidity, per-trade log index (an in-tx index from the trade id
is used), social data, news.

Parsers are pure: (manifest entry, body) -> (records, issues, coverage).
"""
from __future__ import annotations

import json
from dataclasses import dataclass, field

from ...core.models import Coverage, HolderSnapshot, PoolInfo, PoolSnapshot, ProviderBar, Side, Swap, TokenMeta, TokenRef
from ..raw import ManifestEntry
from ..validate import Code, Issue, check_ts, iso_ms, num, valid_address

NAME = "geckoterminal"
BASE = "https://api.geckoterminal.com/api/v2"
HEADERS = {"Accept": "application/json;version=20230302", "User-Agent": "autopsyx-research/0.2"}
TRADES_PAGE = 300  # documented maximum trades per response
MIN = 60_000

# DEX ids whose pricing is a constant-product AMM. Everything else is marked
# non-CPMM so slippage estimates carry status UNVERIFIED.
CPMM_DEXES = {"raydium", "pumpswap", "meteora-damm", "meteora-damm-v2", "uniswap_v2", "sushiswap"}
CLMM_DEXES = {"orca", "raydium-clmm", "meteora", "uniswap_v3", "uniswap-v3", "meteora-dlmm"}


@dataclass
class Parsed:
    records: list = field(default_factory=list)
    issues: list[Issue] = field(default_factory=list)


# ---------------------------------------------------------------- paths ----
def path_new_pools(network: str, page: int) -> str:
    return f"/networks/{network}/new_pools?page={page}"


def path_trending(network: str, page: int = 1) -> str:
    return f"/networks/{network}/trending_pools?page={page}"


def path_top_pools(network: str, page: int = 1) -> str:
    return f"/networks/{network}/pools?page={page}&sort=h24_volume_usd_desc"


def path_pools_multi(network: str, pools: list[str]) -> str:
    return f"/networks/{network}/pools/multi/{','.join(pools)}"


def path_trades(network: str, pool: str) -> str:
    return f"/networks/{network}/pools/{pool}/trades"


def path_ohlcv(network: str, pool: str, limit: int, before_ts_s: int | None = None) -> str:
    p = f"/networks/{network}/pools/{pool}/ohlcv/minute?aggregate=1&limit={limit}&currency=usd"
    return p + (f"&before_timestamp={before_ts_s}" if before_ts_s else "")


def path_token_info(network: str, token: str) -> str:
    return f"/networks/{network}/tokens/{token}/info"


# -------------------------------------------------------------- helpers ----
def _load(e: ManifestEntry, body: bytes, out: Parsed):
    try:
        doc = json.loads(body.decode())
    except (UnicodeDecodeError, json.JSONDecodeError) as exc:
        out.issues.append(Issue(Code.MALFORMED_RECORD, e.raw_id, f"body is not JSON: {exc}", "skipped_response"))
        return None
    if not isinstance(doc, dict) or "data" not in doc:
        out.issues.append(Issue(Code.PARTIAL_RESPONSE, e.raw_id, "response has no 'data' member", "skipped_response"))
        return None
    return doc


def _strip(prefixed: str | None, network: str) -> str | None:
    """GeckoTerminal ids look like 'solana_<address>'."""
    if not isinstance(prefixed, str) or not prefixed.startswith(network + "_"):
        return None
    return prefixed[len(network) + 1:]


def amm_model(dex: str | None) -> str:
    if dex in CPMM_DEXES:
        return "cpmm"
    if dex in CLMM_DEXES:
        return "clmm"
    return "unknown"


# -------------------------------------------------------------- parsers ----
def parse_pools(e: ManifestEntry, body: bytes) -> Parsed:
    """Pool lists (new, trending, top, multi) -> PoolInfo, PoolSnapshot, TokenMeta."""
    out = Parsed()
    doc = _load(e, body, out)
    if doc is None:
        return out
    network = e.context.get("chain", "solana")
    data = doc["data"] if isinstance(doc["data"], list) else [doc["data"]]
    now = e.response_ts
    for item in data:
        try:
            a = item["attributes"]
            rel = item["relationships"]
        except (KeyError, TypeError):
            out.issues.append(Issue(Code.MALFORMED_RECORD, e.raw_id, "pool without attributes/relationships", "dropped_record"))
            continue
        pool = a.get("address")
        token = _strip(rel.get("base_token", {}).get("data", {}).get("id"), network)
        dex = rel.get("dex", {}).get("data", {}).get("id")
        if not valid_address(network, pool) or not valid_address(network, token):
            out.issues.append(Issue(Code.MALFORMED_ADDRESS, e.raw_id, f"pool={pool!r} token={token!r}", "dropped_record"))
            continue
        if item.get("id") and not str(item["id"]).startswith(network + "_"):
            out.issues.append(Issue(Code.CHAIN_MISMATCH, e.raw_id, f"id {item['id']} not on {network}", "dropped_record"))
            continue
        created = iso_ms(a.get("pool_created_at"))
        bad = check_ts(created, now, 5_000)
        if bad:
            out.issues.append(Issue(Code.IMPOSSIBLE_TIMESTAMP, e.raw_id, f"{pool}: pool_created_at {bad}", "dropped_record"))
            continue
        out.records.append(PoolInfo(network, pool, token, dex or "unknown", created, now, amm_model(dex),
                                    30.0, NAME, e.raw_id))
        price = num(a.get("base_token_price_usd"))
        liq = num(a.get("reserve_in_usd"))
        fdv = num(a.get("fdv_usd"))
        name = a.get("name") or ""
        symbol = name.split(" / ")[0].strip() if " / " in name else name
        supply = None
        if price is not None and price > 0 and fdv is not None and fdv > 0:
            supply = fdv / price
            out.issues.append(Issue(Code.DERIVED_FIELD, e.raw_id, f"{token}: total_supply = fdv_usd / price", "derived"))
        out.records.append(TokenMeta(TokenRef(network, token), symbol, symbol, created, None, supply, now,
                                     source=NAME, raw_id=e.raw_id))
        if price is None or liq is None:
            out.issues.append(Issue(Code.NULL_FIELD, e.raw_id, f"{pool}: price={a.get('base_token_price_usd')!r} "
                                    f"reserve={a.get('reserve_in_usd')!r}; no snapshot", "dropped_record"))
            continue
        if price <= 0:
            out.issues.append(Issue(Code.NEGATIVE_PRICE, e.raw_id, f"{pool}: price {price}", "dropped_record"))
            continue
        if liq < 0:
            out.issues.append(Issue(Code.NEGATIVE_LIQUIDITY, e.raw_id, f"{pool}: reserve {liq}", "dropped_record"))
            continue
        tx = a.get("transactions") or {}
        for win, c in tx.items():
            if isinstance(c, dict) and any((num(c.get(k)) or 0) < 0 for k in ("buys", "sells", "buyers", "sellers")):
                out.issues.append(Issue(Code.IMPOSSIBLE_COUNT, e.raw_id, f"{pool}: negative txn count in {win}", "flagged"))
        # Snapshot state is "as of the response"; the provider gives no event time for it.
        out.records.append(PoolSnapshot(network, pool, token, now, now, liq, price, NAME, e.raw_id))
    return out


def parse_trades(e: ManifestEntry, body: bytes, lag_ms: int) -> Parsed:
    """Trades -> Swap records plus a trades Coverage claim for the pool."""
    out = Parsed()
    doc = _load(e, body, out)
    if doc is None:
        return out
    network, pool, token = e.context.get("chain", "solana"), e.context["pool"], e.context["token"]
    now = e.response_ts
    rows = doc["data"] if isinstance(doc["data"], list) else []
    kept_ts = []
    for item in rows:
        try:
            a = item["attributes"]
            tid = str(item["id"])
        except (KeyError, TypeError):
            out.issues.append(Issue(Code.MALFORMED_RECORD, e.raw_id, "trade without attributes", "dropped_record"))
            continue
        ts = iso_ms(a.get("block_timestamp"))
        bad = check_ts(ts, now, 5_000)
        if bad:
            out.issues.append(Issue(Code.IMPOSSIBLE_TIMESTAMP, e.raw_id, f"trade {tid}: {bad}", "dropped_record"))
            continue
        side_raw = a.get("kind")
        if side_raw not in ("buy", "sell"):
            out.issues.append(Issue(Code.MALFORMED_RECORD, e.raw_id, f"trade {tid}: kind {side_raw!r}", "dropped_record"))
            continue
        side = Side(side_raw)
        base_addr = a.get("to_token_address") if side == Side.BUY else a.get("from_token_address")
        if base_addr != token:
            out.issues.append(Issue(Code.TOKEN_PAIR_MISMATCH, e.raw_id,
                                    f"trade {tid}: {side_raw} of {base_addr}, expected {token}", "dropped_record"))
            continue
        wallet = a.get("tx_from_address")
        if not valid_address(network, wallet):
            out.issues.append(Issue(Code.MALFORMED_ADDRESS, e.raw_id, f"trade {tid}: wallet {wallet!r}", "dropped_record"))
            continue
        amount = num(a.get("to_token_amount") if side == Side.BUY else a.get("from_token_amount"))
        price = num(a.get("price_to_in_usd") if side == Side.BUY else a.get("price_from_in_usd"))
        usd = num(a.get("volume_in_usd"))
        block = num(a.get("block_number"))
        if None in (amount, price, usd, block):
            out.issues.append(Issue(Code.NULL_FIELD, e.raw_id, f"trade {tid}: amount/price/volume/block missing", "dropped_record"))
            continue
        if price <= 0 or amount < 0 or usd < 0:
            out.issues.append(Issue(Code.NEGATIVE_PRICE if price <= 0 else Code.NEGATIVE_VOLUME, e.raw_id,
                                    f"trade {tid}: price={price} amount={amount} usd={usd}", "dropped_record"))
            continue
        parts = tid.split("_")
        try:
            log_index = int(parts[3])  # solana_<block>_<tx>_<index>_<unix>
        except (IndexError, ValueError):
            out.issues.append(Issue(Code.MALFORMED_RECORD, e.raw_id, f"trade id {tid!r} has no index", "dropped_record"))
            continue
        out.records.append(Swap(network, a.get("tx_hash") or parts[2], log_index, ts, now, int(block), pool, token,
                                wallet, side, amount, usd, price, NAME, e.raw_id))
        kept_ts.append(ts)
    end = now - lag_ms
    if len(rows) >= TRADES_PAGE:
        start = min(kept_ts) if kept_ts else end
        out.issues.append(Issue(Code.PAGE_FULL, e.raw_id, f"{pool}: {len(rows)} trades returned; coverage starts at "
                                                         f"oldest trade, earlier trades may be missing", "flagged"))
    else:
        start = now - 86_400_000  # fewer than a full page: every trade of the last 24 h was returned
    if start < end:
        out.records.append(Coverage(network, token, pool, "trades", start, end, now, NAME, e.raw_id))
    return out


def parse_ohlcv(e: ManifestEntry, body: bytes, lag_ms: int) -> Parsed:
    """Minute OHLCV -> ProviderBar records plus a bars Coverage claim.

    The in-progress bar and any bar not closed ``lag_ms`` before the response
    are dropped (FORMING_BAR_DROPPED): they are revised later and using them
    would let a partially formed candle stand in for a closed one.
    """
    out = Parsed()
    doc = _load(e, body, out)
    if doc is None:
        return out
    network, pool, token = e.context.get("chain", "solana"), e.context["pool"], e.context["token"]
    now = e.response_ts
    try:
        rows = doc["data"]["attributes"]["ohlcv_list"]
    except (KeyError, TypeError):
        out.issues.append(Issue(Code.PARTIAL_RESPONSE, e.raw_id, "no ohlcv_list", "skipped_response"))
        return out
    meta_base = ((doc.get("meta") or {}).get("base") or {}).get("address")
    if meta_base is not None and meta_base != token:
        out.issues.append(Issue(Code.TOKEN_PAIR_MISMATCH, e.raw_id, f"ohlcv base {meta_base} != {token}", "skipped_response"))
        return out
    closed_before = now - lag_ms
    kept, forming = [], 0
    for r in rows:
        if not isinstance(r, list) or len(r) < 6:
            out.issues.append(Issue(Code.MALFORMED_RECORD, e.raw_id, f"ohlcv row {r!r}", "dropped_record"))
            continue
        t, o, h, l, c, v = (num(x) for x in r[:6])
        if None in (t, o, h, l, c):
            out.issues.append(Issue(Code.NULL_FIELD, e.raw_id, f"ohlcv row {r!r}", "dropped_record"))
            continue
        ts = int(t) * 1000
        bad = check_ts(ts, now, 5_000)
        if bad:
            out.issues.append(Issue(Code.IMPOSSIBLE_TIMESTAMP, e.raw_id, f"bar {ts}: {bad}", "dropped_record"))
            continue
        if ts + MIN > closed_before:
            forming += 1
            continue
        if min(o, h, l, c) <= 0:
            out.issues.append(Issue(Code.NEGATIVE_PRICE, e.raw_id, f"bar {ts}: non-positive price", "dropped_record"))
            continue
        if h < max(o, c, l) or l > min(o, c, h):
            out.issues.append(Issue(Code.IMPOSSIBLE_OHLC, e.raw_id, f"bar {ts}: o={o} h={h} l={l} c={c}", "dropped_record"))
            continue
        if v is not None and v < 0:
            out.issues.append(Issue(Code.NEGATIVE_VOLUME, e.raw_id, f"bar {ts}: volume {v}", "dropped_record"))
            continue
        out.records.append(ProviderBar(network, pool, token, ts, MIN, now, o, h, l, c, v, NAME, e.raw_id))
        kept.append(ts)
    if forming:
        out.issues.append(Issue(Code.FORMING_BAR_DROPPED, e.raw_id, f"{pool}: {forming} unclosed bar(s)", "dropped_record"))
    if kept:
        end = closed_before - closed_before % MIN  # every minute before this is closed
        out.records.append(Coverage(network, token, pool, "bars", min(kept), end, now, NAME, e.raw_id))
    return out


def parse_token_info(e: ManifestEntry, body: bytes) -> Parsed:
    out = Parsed()
    doc = _load(e, body, out)
    if doc is None:
        return out
    network, token = e.context.get("chain", "solana"), e.context["token"]
    try:
        a = doc["data"]["attributes"]
    except (KeyError, TypeError):
        out.issues.append(Issue(Code.PARTIAL_RESPONSE, e.raw_id, "token info without attributes", "skipped_response"))
        return out
    if a.get("address") != token:
        out.issues.append(Issue(Code.TOKEN_PAIR_MISMATCH, e.raw_id, f"info for {a.get('address')}, expected {token}",
                                "skipped_response"))
        return out
    now = e.response_ts
    dev = a.get("developer_address")
    if dev is not None and not valid_address(network, dev):
        out.issues.append(Issue(Code.MALFORMED_ADDRESS, e.raw_id, f"developer_address {dev!r}", "dropped_field"))
        dev = None
    prior = e.context.get("pool_created_ts")
    out.records.append(TokenMeta(TokenRef(network, token), a.get("symbol") or "", a.get("name") or "",
                                 prior, dev, e.context.get("total_supply"), now, source=NAME, raw_id=e.raw_id))
    h = a.get("holders") or {}
    count = num(h.get("count"))
    dist = h.get("distribution_percentage") or {}
    top10 = num(dist.get("top_10"))
    updated = iso_ms(h.get("last_updated"))
    if count is None or top10 is None:
        out.issues.append(Issue(Code.NULL_FIELD, e.raw_id, f"{token}: holders unavailable", "dropped_record"))
        return out
    if count < 0 or not 0 <= top10 <= 100:
        out.issues.append(Issue(Code.IMPOSSIBLE_COUNT, e.raw_id, f"{token}: holders={count} top10={top10}", "dropped_record"))
        return out
    bad = check_ts(updated, now, 5_000)
    if bad:
        out.issues.append(Issue(Code.IMPOSSIBLE_TIMESTAMP, e.raw_id, f"{token}: holders.last_updated {bad}", "dropped_record"))
        return out
    dev_pct = num(a.get("developer_holding_percentage"))
    out.records.append(HolderSnapshot(network, token, updated, now, int(count), top10 / 100.0,
                                      dev_pct / 100.0 if dev_pct is not None else None, NAME, e.raw_id))
    return out
