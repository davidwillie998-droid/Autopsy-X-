"""Phase 3A normalization: raw archive -> Observation records.

Additive by design: Phase 2's ``normalize()`` and its committed dataset
hashes are untouched. This module reads only the Phase 3A endpoints, and its
output is deterministic for a given run directory.
"""
from __future__ import annotations

import hashlib
import json

from ..core.observation import Observation, dedupe
from ..core.observation import Availability as A
from ..core.observation import validate
from .providers import geckoterminal as gt
from .providers import solana_rpc as rpc
from .raw import RawStore
from .validate import Code, Issue

def _rpc_transaction(e, body):
    if e.context.get("purpose") == "liquidity":
        return rpc.parse_liquidity(e, body)
    return rpc.parse_transaction(e, body)


def _pool_created(e, body):
    """Pool-creation events from GeckoTerminal pool metadata (pool_created_at).

    The provider's creation time is the source time; the event becomes
    visible only when the response arrived. No amounts are claimed: the
    metadata says when the pool appeared, not how much liquidity it got.
    """
    out = rpc.Parsed()
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


PARSERS = {
    "rpc.signatures": rpc.parse_signatures,
    "rpc.transaction": _rpc_transaction,
    "gt.new_pools": _pool_created,
    "gt.trending": _pool_created,
    "gt.top_pools": _pool_created,
    "gt.pools_multi": _pool_created,
}


def normalize_phase3a(run_dir: str) -> tuple[list[Observation], list[Issue]]:
    raw = RawStore(run_dir)
    obs: list[Observation] = []
    issues: list[Issue] = []
    for e in raw.entries():
        parse = PARSERS.get(e.endpoint)
        if parse is None:
            continue
        body = raw.body(e.raw_id) if e.raw_id else None
        p = parse(e, body)
        obs += p.observations
        issues += p.issues
    kept, dups = dedupe(obs)
    for d in dups:
        issues.append(Issue(Code.DUPLICATE_OBSERVATION, d.raw_id, f"{d.kind} {d.signature or d.entity}", "dropped_record"))
    return kept, issues


def observations_sha256(obs: list[Observation]) -> str:
    h = hashlib.sha256()
    for o in obs:
        h.update(json.dumps(o.to_dict(), sort_keys=True).encode() + b"\n")
    return h.hexdigest()
