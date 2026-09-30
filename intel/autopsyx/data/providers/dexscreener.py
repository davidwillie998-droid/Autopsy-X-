"""DexScreener public API adapter (api.dexscreener.com, no key).

Used as the second, independent source for pool price and liquidity, so
cross-source conflicts can be detected. Provides aggregate txn counts and
volumes per window but no trades, no wallets, no OHLCV.
"""
from __future__ import annotations

import json

from ...core.models import PoolSnapshot
from ..raw import ManifestEntry
from ..validate import Code, Issue, num, valid_address
from .geckoterminal import Parsed

NAME = "dexscreener"
BASE = "https://api.dexscreener.com"
HEADERS = {"Accept": "application/json", "User-Agent": "autopsyx-research/0.2"}
MAX_PAIRS_PER_CALL = 30


def path_pairs(chain: str, pairs: list[str]) -> str:
    return f"/latest/dex/pairs/{chain}/{','.join(pairs)}"


def parse_pairs(e: ManifestEntry, body: bytes) -> Parsed:
    out = Parsed()
    try:
        doc = json.loads(body.decode())
    except (UnicodeDecodeError, json.JSONDecodeError) as exc:
        out.issues.append(Issue(Code.MALFORMED_RECORD, e.raw_id, f"body is not JSON: {exc}", "skipped_response"))
        return out
    pairs = doc.get("pairs") if isinstance(doc, dict) else None
    if pairs is None:
        out.issues.append(Issue(Code.PARTIAL_RESPONSE, e.raw_id, "no 'pairs' member (unknown pair or error)",
                                "skipped_response"))
        return out
    chain = e.context.get("chain", "solana")
    requested = dict(e.context.get("pool_tokens", {}))  # pool -> token
    now = e.response_ts
    seen = set()
    for p in pairs:
        pool = p.get("pairAddress")
        if p.get("chainId") != chain:
            out.issues.append(Issue(Code.CHAIN_MISMATCH, e.raw_id, f"{pool}: chainId {p.get('chainId')}", "dropped_record"))
            continue
        token = (p.get("baseToken") or {}).get("address")
        if not valid_address(chain, pool) or not valid_address(chain, token):
            out.issues.append(Issue(Code.MALFORMED_ADDRESS, e.raw_id, f"pool={pool!r} token={token!r}", "dropped_record"))
            continue
        if requested and requested.get(pool) != token:
            out.issues.append(Issue(Code.CONFLICTING_METADATA, e.raw_id,
                                    f"{pool}: base token {token} != {requested.get(pool)} from GeckoTerminal", "dropped_record"))
            continue
        seen.add(pool)
        price = num(p.get("priceUsd"))
        liq = num((p.get("liquidity") or {}).get("usd"))
        if price is None or liq is None:
            out.issues.append(Issue(Code.NULL_FIELD, e.raw_id, f"{pool}: priceUsd={p.get('priceUsd')!r} "
                                    f"liquidity={p.get('liquidity')!r}", "dropped_record"))
            continue
        if price <= 0 or liq < 0:
            out.issues.append(Issue(Code.NEGATIVE_PRICE if price <= 0 else Code.NEGATIVE_LIQUIDITY, e.raw_id,
                                    f"{pool}: price={price} liquidity={liq}", "dropped_record"))
            continue
        out.records.append(PoolSnapshot(chain, pool, token, now, now, liq, price, NAME, e.raw_id))
    for pool in requested:
        if pool not in seen:
            out.issues.append(Issue(Code.PARTIAL_RESPONSE, e.raw_id, f"{pool}: requested but not returned", "flagged"))
    return out
