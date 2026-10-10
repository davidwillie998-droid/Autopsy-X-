"""Solana JSON-RPC adapter (any standard RPC endpoint; the public one needs no key).

Two calls are used, both read-only:
  getSignaturesForAddress  newest-first signature index for an address,
                           paginated with ``before``
  getTransaction           one transaction, ``jsonParsed`` encoding, so system
                           and SPL-token instructions arrive decoded

Funding-transfer observations come from system ``transfer`` /
``transferWithSeed`` and SPL-token ``transfer`` / ``transferChecked``
instructions, top-level and inner. Rules the parser keeps:

* A signer is not a beneficiary. ``signers`` and ``fee_payer`` are what the
  transaction says; ``beneficiary`` is never inferred and is always
  ``beneficiary_status = UNKNOWN``.
* A failed transaction (``meta.err`` set) is kept with ``tx_status =
  "failed"``; it is evidence that a transfer was attempted, not that value
  moved.
* A missing ``blockTime`` leaves ``source_ts`` empty with state
  NOT_OBSERVED. The ingestion time is never substituted for it.
* Every request that fails (transport, HTTP, RPC ``error`` object, malformed
  body) becomes an ERROR observation, so a coverage gap stays visible.

Parsers are pure: (manifest entry, body) -> Parsed(observations, issues, ...).
"""
from __future__ import annotations

import json
import os
from dataclasses import dataclass, field
from decimal import Decimal
from urllib.parse import urlsplit

from ...core.observation import Availability as A
from ...core.observation import Observation, validate
from ..raw import ManifestEntry
from ..validate import Code, Issue, valid_address

NAME = "solana_rpc"
PUBLIC_BASE = "https://api.mainnet-beta.solana.com"
# A private endpoint may carry a key in its URL; it is read from the environment
# only and never written to the archive (see ``display_base``).
BASE = os.environ.get("AUTOPSYX_SOLANA_RPC_URL") or PUBLIC_BASE
HEADERS = {"User-Agent": "autopsyx-research/0.3"}
CHAIN = "solana"
SYSTEM = "system"
TOKEN_PROGRAMS = {"spl-token", "spl-token-2022"}
SYSTEM_TRANSFERS = {"transfer", "transferWithSeed"}
TOKEN_TRANSFERS = {"transfer", "transferChecked"}
LAMPORTS = Decimal(10) ** 9
PURPOSE_KIND = {"funding": "funding_transfer", "liquidity": "liquidity_event"}


def display_base(base: str) -> str:
    """What the manifest records for an endpoint: scheme and host only, so a key
    embedded in a private RPC URL (path or query) never reaches the archive."""
    if base == PUBLIC_BASE:
        return base
    u = urlsplit(base)
    host = (u.hostname or "unknown").split("@")[-1]
    return f"{u.scheme}://{host}/<redacted>"


@dataclass
class Parsed:
    observations: list = field(default_factory=list)
    issues: list[Issue] = field(default_factory=list)
    signatures: list[dict] = field(default_factory=list)  # getSignaturesForAddress rows
    next_before: str | None = None  # pagination cursor when the page was full


# ------------------------------------------------------------- requests ----
def req_signatures(address: str, limit: int, before: str | None = None) -> dict:
    opts = {"limit": limit, "commitment": "finalized"}
    if before:
        opts["before"] = before
    return {"jsonrpc": "2.0", "id": 1, "method": "getSignaturesForAddress", "params": [address, opts]}


def req_transaction(signature: str) -> dict:
    return {"jsonrpc": "2.0", "id": 1, "method": "getTransaction",
            "params": [signature, {"encoding": "jsonParsed", "maxSupportedTransactionVersion": 0,
                                   "commitment": "finalized"}]}


# -------------------------------------------------------------- helpers ----
def _base_obs(e: ManifestEntry, entity: str, state: A, reason: str, kind: str = "funding_transfer",
              signature: str | None = None) -> Observation:
    t = e.response_ts if e.response_ts is not None else e.request_ts
    return validate(Observation(kind=kind, entity=entity, chain=CHAIN, venue=None, state=state, observation_ts=t,
                                source_ts=None, source_ts_state=A.NOT_OBSERVED, ingestion_ts=t, provider=NAME,
                                response_status=e.status, raw_id=e.raw_id, signature=signature, reason=reason))


def _rpc_result(e: ManifestEntry, body: bytes | None, entity: str, out: Parsed, kind: str = "funding_transfer"):
    """Return (ok, result). Failures are recorded as ERROR observations."""
    sig = e.context.get("signature")
    if body is None:
        out.observations.append(_base_obs(e, entity, A.ERROR, f"request failed: {e.error}", kind, sig))
        out.issues.append(Issue(Code.PROVIDER_ERROR, None, f"{e.endpoint} {entity}: {e.error}", "skipped_response"))
        return False, None
    try:
        doc = json.loads(body.decode())
    except (UnicodeDecodeError, ValueError) as exc:
        out.observations.append(_base_obs(e, entity, A.ERROR, f"malformed RPC body: {exc}", kind, sig))
        out.issues.append(Issue(Code.MALFORMED_RECORD, e.raw_id, f"body is not JSON: {exc}", "skipped_response"))
        return False, None
    if not isinstance(doc, dict) or ("result" not in doc and "error" not in doc):
        out.observations.append(_base_obs(e, entity, A.ERROR, "malformed RPC body: no result or error member", kind, sig))
        out.issues.append(Issue(Code.MALFORMED_RECORD, e.raw_id, "JSON-RPC envelope missing result/error", "skipped_response"))
        return False, None
    if doc.get("error") is not None:
        err = doc["error"]
        msg = err.get("message") if isinstance(err, dict) else str(err)
        code = err.get("code") if isinstance(err, dict) else None
        out.observations.append(_base_obs(e, entity, A.ERROR, f"RPC error {code}: {msg}", kind, sig))
        out.issues.append(Issue(Code.PROVIDER_ERROR, e.raw_id, f"RPC error {code}: {msg}", "skipped_response"))
        return False, None
    return True, doc["result"]


# ---------------------------------------------------------- signatures ----
def parse_signatures(e: ManifestEntry, body: bytes | None) -> Parsed:
    """Signature index for one address. Rows are kept in provider order."""
    out = Parsed()
    address = e.context.get("address", "")
    kind = PURPOSE_KIND.get(e.context.get("purpose", "funding"), "funding_transfer")
    ok, result = _rpc_result(e, body, address, out, kind)
    if not ok:
        return out
    if not isinstance(result, list):
        out.observations.append(_base_obs(e, address, A.ERROR, "malformed RPC body: result is not a list", kind))
        out.issues.append(Issue(Code.MALFORMED_RECORD, e.raw_id, "signatures result not a list", "skipped_response"))
        return out
    for row in result:
        if not isinstance(row, dict) or not isinstance(row.get("signature"), str) or not isinstance(row.get("slot"), int):
            out.issues.append(Issue(Code.MALFORMED_RECORD, e.raw_id, f"signature row {row!r:.80}", "dropped_record"))
            continue
        bt = row.get("blockTime")
        out.signatures.append({"signature": row["signature"], "slot": row["slot"],
                               "block_time_ms": bt * 1000 if isinstance(bt, int) else None,
                               "failed": row.get("err") is not None})
    limit = e.context.get("limit")
    if isinstance(limit, int) and len(result) >= limit and out.signatures:
        out.next_before = out.signatures[-1]["signature"]
    return out


# --------------------------------------------------------- transactions ----
def _instructions(tx: dict) -> list[tuple[int, int | None, dict]]:
    """(outer index, inner index or None, instruction) in execution order."""
    msg = tx["transaction"]["message"]
    inner = {}
    for block in (tx.get("meta") or {}).get("innerInstructions") or []:
        inner[block.get("index")] = block.get("instructions") or []
    out = []
    for i, ins in enumerate(msg.get("instructions") or []):
        out.append((i, None, ins))
        for j, sub in enumerate(inner.get(i, [])):
            out.append((i, j, sub))
    return out


def _token_accounts(tx: dict, keys: list[str]) -> dict[str, dict]:
    """token account -> {owner, mint, decimals}, from the balances the RPC reported."""
    meta = tx.get("meta") or {}
    accts: dict[str, dict] = {}
    for bal in (meta.get("preTokenBalances") or []) + (meta.get("postTokenBalances") or []):
        idx = bal.get("accountIndex")
        if not isinstance(idx, int) or idx >= len(keys):
            continue
        ui = bal.get("uiTokenAmount") or {}
        accts.setdefault(keys[idx], {"owner": bal.get("owner"), "mint": bal.get("mint"), "decimals": ui.get("decimals")})
    return accts


def _state(v) -> str:
    return A.OBSERVED.value if v is not None else A.NOT_OBSERVED.value


def parse_transaction(e: ManifestEntry, body: bytes | None) -> Parsed:
    """Funding-transfer observations for the watched address in one transaction.

    One OBSERVED record per transfer instruction touching the address (as
    source, destination, or owner of either token account). A transaction that
    touches the address without such a transfer yields one NOT_OBSERVED record,
    so every fetched signature is accounted for.
    """
    out = Parsed()
    address = e.context.get("address", "")
    sig = e.context.get("signature")
    ok, tx = _rpc_result(e, body, address, out)
    if not ok:
        return out
    if tx is None:
        out.observations.append(_base_obs(e, address, A.NOT_OBSERVED, "RPC returned null: transaction not found", signature=sig))
        return out
    try:
        msg = tx["transaction"]["message"]
        keys = [k["pubkey"] if isinstance(k, dict) else k for k in msg["accountKeys"]]
        signers = [k["pubkey"] for k in msg["accountKeys"] if isinstance(k, dict) and k.get("signer")]
        tx_sig = tx["transaction"]["signatures"][0]
        slot = tx["slot"]
        steps = _instructions(tx)
    except (KeyError, IndexError, TypeError) as exc:
        out.observations.append(_base_obs(e, address, A.ERROR, f"malformed transaction: missing {exc}", signature=sig))
        out.issues.append(Issue(Code.MALFORMED_RECORD, e.raw_id, f"transaction {sig}: missing {exc}", "skipped_response"))
        return out
    if sig is not None and tx_sig != sig:
        out.observations.append(_base_obs(e, address, A.ERROR, f"RPC answered for {tx_sig}, asked {sig}", signature=sig))
        out.issues.append(Issue(Code.MALFORMED_RECORD, e.raw_id, f"signature mismatch {tx_sig} != {sig}", "skipped_response"))
        return out
    meta = tx.get("meta")
    tx_status = "unknown" if meta is None else ("failed" if meta.get("err") is not None else "success")
    bt = tx.get("blockTime")
    src_ts = bt * 1000 if isinstance(bt, int) else None
    ing = e.response_ts
    accts = _token_accounts(tx, keys)
    common = dict(kind="funding_transfer", entity=address, chain=CHAIN, venue=None, state=A.OBSERVED,
                  observation_ts=src_ts if src_ts is not None else ing, source_ts=src_ts,
                  source_ts_state=A.OBSERVED if src_ts is not None else A.NOT_OBSERVED, ingestion_ts=ing,
                  provider=NAME, response_status=e.status, raw_id=e.raw_id, slot=slot, signature=tx_sig)
    found = 0
    for outer, inner, ins in steps:
        prog, parsed = ins.get("program"), ins.get("parsed")
        if not isinstance(parsed, dict):
            continue
        typ, info = parsed.get("type"), parsed.get("info") or {}
        if prog == SYSTEM and typ in SYSTEM_TRANSFERS:
            lamports = info.get("lamports")
            src, dst = info.get("source"), info.get("destination")
            if not isinstance(lamports, int) or not valid_address(CHAIN, src) or not valid_address(CHAIN, dst):
                out.issues.append(Issue(Code.MALFORMED_RECORD, e.raw_id, f"{tx_sig} system {typ} {info!r:.80}", "dropped_record"))
                continue
            v = {"program": "system", "instruction": typ, "source": src, "destination": dst,
                 "source_owner": None, "source_owner_state": A.NOT_APPLICABLE.value,
                 "destination_owner": None, "destination_owner_state": A.NOT_APPLICABLE.value,
                 "amount": str(Decimal(lamports) / LAMPORTS), "amount_state": A.OBSERVED.value,
                 "amount_raw": str(lamports), "decimals": 9, "native": True,
                 "mint": None, "mint_state": A.NOT_APPLICABLE.value, "authority": src}
        elif prog in TOKEN_PROGRAMS and typ in TOKEN_TRANSFERS:
            src, dst = info.get("source"), info.get("destination")
            ta = info.get("tokenAmount") or {}
            raw_amt = ta.get("amount") if typ == "transferChecked" else info.get("amount")
            if not isinstance(raw_amt, str) or not raw_amt.isdigit() or not valid_address(CHAIN, src) or not valid_address(CHAIN, dst):
                out.issues.append(Issue(Code.MALFORMED_RECORD, e.raw_id, f"{tx_sig} token {typ} {info!r:.80}", "dropped_record"))
                continue
            sa, da = accts.get(src, {}), accts.get(dst, {})
            mint = info.get("mint") or sa.get("mint") or da.get("mint")
            dec = ta.get("decimals") if typ == "transferChecked" else (sa.get("decimals") or da.get("decimals"))
            amount = str(Decimal(raw_amt) / (Decimal(10) ** dec)) if isinstance(dec, int) else None
            v = {"program": prog, "instruction": typ, "source": src, "destination": dst,
                 "source_owner": sa.get("owner"), "source_owner_state": _state(sa.get("owner")),
                 "destination_owner": da.get("owner"), "destination_owner_state": _state(da.get("owner")),
                 "amount": amount, "amount_state": _state(amount), "amount_raw": raw_amt,
                 "decimals": dec if isinstance(dec, int) else None, "native": False,
                 "mint": mint, "mint_state": _state(mint),
                 "authority": info.get("authority") or info.get("multisigAuthority")}
        else:
            continue
        sides = {v["source"], v["source_owner"]}, {v["destination"], v["destination_owner"]}
        if address not in sides[0] | sides[1]:
            continue
        v["direction"] = "self" if address in sides[0] and address in sides[1] else ("out" if address in sides[0] else "in")
        v.update({"tx_status": tx_status, "tx_err": json.dumps(meta.get("err"), sort_keys=True) if meta and meta.get("err") is not None else None,
                  "signers": signers, "fee_payer": keys[0] if keys else None,
                  "beneficiary": None, "beneficiary_status": A.UNKNOWN.value,
                  "instruction_index": outer, "inner_index": inner})
        out.observations.append(validate(Observation(**common, value=v)))
        found += 1
    if not found:
        o = Observation(**{**common, "state": A.NOT_OBSERVED},
                        reason=f"transaction ({tx_status}) has no system/SPL transfer touching {address}")
        out.observations.append(validate(o))
    return out


# ------------------------------------------------------ liquidity events ----
def parse_liquidity(e: ManifestEntry, body: bytes | None) -> Parsed:
    """Liquidity-event observation for one transaction of a watched pool.

    Program-agnostic: the pool's vaults are the token accounts whose reported
    owner is the pool address, and the event is classified from their
    pre/post balance deltas, never from current pool state:

      vault absent before, present after   pool_create
      base and quote vault both up         add
      base and quote vault both down       remove
      opposite directions                  swap (not a liquidity event: NOT_OBSERVED)
      anything else                        unclassified (OBSERVED, deltas kept)

    Venues whose vault authority is not the pool address (e.g. a separate AMM
    authority) yield NOT_OBSERVED with that reason: the method cannot see
    them, which is a coverage gap and not evidence of no liquidity change.
    """
    out = Parsed()
    pool = e.context.get("pool") or e.context.get("address", "")
    base = e.context.get("token")
    sig = e.context.get("signature")
    ok, tx = _rpc_result(e, body, pool, out, "liquidity_event")
    if not ok:
        return out
    if tx is None:
        out.observations.append(_base_obs(e, pool, A.NOT_OBSERVED, "RPC returned null: transaction not found",
                                          "liquidity_event", sig))
        return out
    try:
        keys = [k["pubkey"] if isinstance(k, dict) else k for k in tx["transaction"]["message"]["accountKeys"]]
        tx_sig = tx["transaction"]["signatures"][0]
        slot = tx["slot"]
    except (KeyError, IndexError, TypeError) as exc:
        out.observations.append(_base_obs(e, pool, A.ERROR, f"malformed transaction: missing {exc}", "liquidity_event", sig))
        out.issues.append(Issue(Code.MALFORMED_RECORD, e.raw_id, f"transaction {sig}: missing {exc}", "skipped_response"))
        return out
    if sig is not None and tx_sig != sig:
        out.observations.append(_base_obs(e, pool, A.ERROR, f"RPC answered for {tx_sig}, asked {sig}", "liquidity_event", sig))
        out.issues.append(Issue(Code.MALFORMED_RECORD, e.raw_id, f"signature mismatch {tx_sig} != {sig}", "skipped_response"))
        return out
    meta = tx.get("meta")
    tx_status = "unknown" if meta is None else ("failed" if meta.get("err") is not None else "success")
    bt = tx.get("blockTime")
    src_ts = bt * 1000 if isinstance(bt, int) else None
    common = dict(kind="liquidity_event", entity=pool, chain=CHAIN, venue=e.context.get("dex"),
                  observation_ts=src_ts if src_ts is not None else e.response_ts, source_ts=src_ts,
                  source_ts_state=A.OBSERVED if src_ts is not None else A.NOT_OBSERVED, ingestion_ts=e.response_ts,
                  provider=NAME, response_status=e.status, raw_id=e.raw_id, slot=slot, signature=tx_sig)

    def none(reason: str) -> Parsed:
        out.observations.append(validate(Observation(**common, state=A.NOT_OBSERVED, reason=reason)))
        return out

    if meta is None:
        return none("transaction has no meta: balances unknown")
    vaults: dict[str, dict] = {}
    for when in ("pre", "post"):
        for bal in meta.get(f"{when}TokenBalances") or []:
            idx = bal.get("accountIndex")
            if bal.get("owner") != pool or not isinstance(idx, int) or idx >= len(keys):
                continue
            amt = (bal.get("uiTokenAmount") or {}).get("amount")
            if not isinstance(amt, str) or not amt.isdigit():
                out.issues.append(Issue(Code.MALFORMED_RECORD, e.raw_id, f"{tx_sig} vault balance {amt!r}", "dropped_field"))
                continue
            v = vaults.setdefault(keys[idx], {"vault": keys[idx], "mint": bal.get("mint"), "pre": None, "post": None})
            v[when] = int(amt)
    if not vaults:
        return none(f"no token account owned by the pool address in this transaction ({tx_status}); "
                    "vault authority may differ from the pool address")
    if tx_status == "failed":
        return none("failed transaction: no balance change took effect")
    deltas = []
    for v in sorted(vaults.values(), key=lambda x: x["vault"]):
        d = None if v["post"] is None else v["post"] - (v["pre"] or 0)
        deltas.append({**v, "pre": None if v["pre"] is None else str(v["pre"]),
                       "post": None if v["post"] is None else str(v["post"]),
                       "delta_raw": None if d is None else str(d)})
    created = any(v["pre"] is None and v["post"] is not None for v in vaults.values())
    signs = {}
    for v in deltas:
        if v["delta_raw"] is not None:
            signs.setdefault("base" if v["mint"] == base else "quote", []).append(int(v["delta_raw"]))
    b = sum(signs.get("base", [])) if "base" in signs else None
    q = sum(signs.get("quote", [])) if "quote" in signs else None
    if created:
        typ = "pool_create"
    elif b is None or q is None or b == 0 or q == 0:
        if (b or 0) == 0 and (q or 0) == 0:
            return none("pool vault balances unchanged")
        typ = "unclassified"
    elif b > 0 and q > 0:
        typ = "add"
    elif b < 0 and q < 0:
        typ = "remove"
    else:
        return none("vault deltas in opposite directions: swap, not a liquidity event")
    quote_mints = sorted({v["mint"] for v in deltas if v["mint"] != base and v["mint"]})
    value = {"event_type": typ, "pool": pool, "base_mint": base, "quote_mint": quote_mints[0] if len(quote_mints) == 1 else None,
             "quote_mint_state": A.OBSERVED.value if len(quote_mints) == 1 else A.UNKNOWN.value,
             "base_amount_raw": None if b is None else str(b), "base_amount_raw_state": _state(b),
             "quote_amount_raw": None if q is None else str(q), "quote_amount_raw_state": _state(q),
             "vault_deltas": deltas, "classification_method": "vault_balance_delta", "tx_status": tx_status}
    out.observations.append(validate(Observation(**common, state=A.OBSERVED, value=value)))
    return out
