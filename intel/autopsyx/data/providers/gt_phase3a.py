"""Phase 3A parsers over GeckoTerminal responses.

Separate from ``geckoterminal.py`` on purpose: the Phase 2 parsers (and the
dataset hashes committed from them) stay byte-for-byte unchanged. These
parsers read the same archived bodies and emit Observation records with
explicit availability states instead of dropping what is missing.
"""
from __future__ import annotations

import json

from ...core.observation import Availability as A
from ...core.observation import Observation, validate
from ..raw import ManifestEntry
from ..validate import Code, Issue, check_ts, iso_ms, num, valid_address
from . import geckoterminal as gt
from .solana_rpc import Parsed


def pool_created(e: ManifestEntry, body: bytes | None) -> Parsed:
    """Pool-creation events from pool metadata (``pool_created_at``).

    The provider's creation time is the source time; the event becomes
    visible only when the response arrived. No amounts are claimed: the
    metadata says when the pool appeared, not how much liquidity it got.
    """
    out = Parsed()
    if body is None:
        return out
    for r in gt.parse_pools(e, body).records:
        if type(r).__name__ != "PoolInfo":
            continue
        has_ts = r.created_ts is not None
        out.observations.append(validate(Observation(
            kind="liquidity_event", entity=r.pool, chain=r.chain, venue=r.venue, state=A.OBSERVED,
            observation_ts=r.created_ts if has_ts else e.response_ts, source_ts=r.created_ts,
            source_ts_state=A.OBSERVED if has_ts else A.NOT_OBSERVED, ingestion_ts=e.response_ts,
            provider=gt.NAME, response_status=e.status, raw_id=e.raw_id,
            value={"event_type": "pool_create", "pool": r.pool, "base_mint": r.token,
                   "quote_mint": None, "quote_mint_state": A.NOT_OBSERVED.value,
                   "base_amount_raw": None, "base_amount_raw_state": A.NOT_OBSERVED.value,
                   "quote_amount_raw": None, "quote_amount_raw_state": A.NOT_OBSERVED.value,
                   "vault_deltas": None, "vault_deltas_state": A.NOT_OBSERVED.value,
                   "classification_method": "provider_metadata:pool_created_at",
                   "tx_status": None, "tx_status_state": A.NOT_APPLICABLE.value})))
    return out


def _empty(e: ManifestEntry, kind: str, token: str, state: A, reason: str) -> Observation:
    t = e.response_ts if e.response_ts is not None else e.request_ts
    return validate(Observation(kind=kind, entity=token, chain=e.context.get("chain", "solana"), venue=None,
                                state=state, observation_ts=t, source_ts=None, source_ts_state=A.NOT_OBSERVED,
                                ingestion_ts=t, provider=gt.NAME, response_status=e.status, raw_id=e.raw_id,
                                reason=reason))


def token_state(e: ManifestEntry, body: bytes | None) -> Parsed:
    """Token info -> one creator_state and one holder_state observation.

    A null ``developer_address`` or null ``holders`` is NOT_OBSERVED (the
    provider answered without the fact), never "no creator" or "no holders".
    A failed or malformed response is ERROR for both.
    """
    out = Parsed()
    token = e.context.get("token", "")
    network = e.context.get("chain", "solana")
    if body is None:
        for k in ("creator_state", "holder_state"):
            out.observations.append(_empty(e, k, token, A.ERROR, f"request failed: {e.error}"))
        return out
    try:
        a = json.loads(body.decode())["data"]["attributes"]
        if a.get("address") != token:
            raise ValueError(f"info for {a.get('address')}, expected {token}")
    except (UnicodeDecodeError, ValueError, KeyError, TypeError) as exc:
        for k in ("creator_state", "holder_state"):
            out.observations.append(_empty(e, k, token, A.ERROR, f"malformed token info: {exc}"))
        out.issues.append(Issue(Code.MALFORMED_RECORD, e.raw_id, f"token info {token}: {exc}", "skipped_response"))
        return out
    now = e.response_ts
    base = dict(entity=token, chain=network, venue=None, observation_ts=now, ingestion_ts=now, provider=gt.NAME,
                response_status=e.status, raw_id=e.raw_id)

    dev = a.get("developer_address")
    if dev is None:
        out.observations.append(_empty(e, "creator_state", token, A.NOT_OBSERVED, "provider returned developer_address null"))
    elif not valid_address(network, dev):
        out.observations.append(_empty(e, "creator_state", token, A.ERROR, f"malformed developer_address {dev!r}"))
        out.issues.append(Issue(Code.MALFORMED_ADDRESS, e.raw_id, f"developer_address {dev!r}", "dropped_field"))
    else:
        pct = num(a.get("developer_holding_percentage"))
        if pct is not None and not 0 <= pct <= 100:
            out.issues.append(Issue(Code.IMPOSSIBLE_COUNT, e.raw_id, f"{token}: developer pct {pct}", "dropped_field"))
            pct = None
        out.observations.append(validate(Observation(
            kind="creator_state", state=A.OBSERVED, source_ts=None, source_ts_state=A.NOT_OBSERVED, **base,
            value={"creator": dev, "creator_state": A.OBSERVED.value,
                   "creator_pct": pct / 100.0 if pct is not None else None, "creator_pct_state":
                   A.OBSERVED.value if pct is not None else A.NOT_OBSERVED.value})))

    h = a.get("holders")
    if not isinstance(h, dict):
        out.observations.append(_empty(e, "holder_state", token, A.NOT_OBSERVED, "provider returned holders null"))
        return out
    count = num(h.get("count"))
    top10 = num((h.get("distribution_percentage") or {}).get("top_10"))
    updated = iso_ms(h.get("last_updated"))
    if (count is not None and count < 0) or (top10 is not None and not 0 <= top10 <= 100):
        out.observations.append(_empty(e, "holder_state", token, A.ERROR, f"impossible holders={count} top10={top10}"))
        out.issues.append(Issue(Code.IMPOSSIBLE_COUNT, e.raw_id, f"{token}: holders={count} top10={top10}", "skipped_response"))
        return out
    if count is None and top10 is None:
        out.observations.append(_empty(e, "holder_state", token, A.NOT_OBSERVED, "provider returned holder count and top-10 share null"))
        return out
    ts_ok = updated is not None and not check_ts(updated, now, 5_000)
    out.observations.append(validate(Observation(
        kind="holder_state", state=A.OBSERVED, source_ts=updated if ts_ok else None,
        source_ts_state=A.OBSERVED if ts_ok else A.NOT_OBSERVED, **base,
        value={"holder_count": int(count) if count is not None else None, "holder_count_state": A.OBSERVED.value
               if count is not None else A.NOT_OBSERVED.value,
               "top10_share": top10 / 100.0 if top10 is not None else None, "top10_share_state": A.OBSERVED.value
               if top10 is not None else A.NOT_OBSERVED.value})))
    return out
