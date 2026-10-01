"""Phase 3A normalization: raw archive -> Observation records.

Additive by design: Phase 2's ``normalize()`` and its committed dataset
hashes are untouched. This module reads only the Phase 3A endpoints, and its
output is deterministic for a given run directory.
"""
from __future__ import annotations

import hashlib
import json

from ..core.observation import Observation, dedupe
from .providers import gt_phase3a as gt3
from .providers import solana_rpc as rpc
from .raw import RawStore
from .validate import Code, Issue


def _rpc_transaction(e, body):
    if e.context.get("purpose") == "liquidity":
        return rpc.parse_liquidity(e, body)
    return rpc.parse_transaction(e, body)


PARSERS = {
    "rpc.signatures": rpc.parse_signatures,
    "rpc.transaction": _rpc_transaction,
    "gt.new_pools": gt3.pool_created,
    "gt.trending": gt3.pool_created,
    "gt.top_pools": gt3.pool_created,
    "gt.pools_multi": gt3.pool_created,
    "gt.token_info": gt3.token_state,
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
