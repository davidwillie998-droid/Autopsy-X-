"""Solana RPC funding-transfer adapter.

Fixtures are constructed in the shape the RPC returns for ``jsonParsed``
(system and SPL-token instructions, inner instructions, token balances);
they are not captured responses.
"""
import json
import urllib.error

import pytest

from autopsyx.core.observation import Availability as A
from autopsyx.core.observation import validate
from autopsyx.data import acquire
from autopsyx.data.normalize3a import normalize_phase3a, observations_sha256
from autopsyx.data.providers import solana_rpc as rpc
from autopsyx.data.raw import RawStore
from autopsyx.providers.http import CircuitBreaker, HttpClient, TokenBucket
from autopsyx.providers.store import EventStore

from phase2_fakes import _Resp

B58 = "123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz"


def addr(n: int) -> str:
    s, x = "", n + 7919
    while len(s) < 44:
        s += B58[x % 58]
        x = x * 31 + 17
    return s


WALLET, FUNDER, OTHER, MINT, ATA_W, ATA_F, RELAYER = (addr(i) for i in range(7))
T0 = 1_790_000_000_000


def sig(n: int) -> str:
    return addr(100 + n)[:43] + "1"


def tx(signature, *, block_time=1_789_999_000, err=None, instructions=None, inner=None, slot=300_000_000,
       signer=FUNDER, balances=None):
    keys = [{"pubkey": signer, "signer": True, "writable": True},
            {"pubkey": WALLET, "signer": False, "writable": True}]
    return {"slot": slot, "blockTime": block_time,
            "meta": {"err": err, "innerInstructions": inner or [], "preTokenBalances": balances or [],
                     "postTokenBalances": balances or []},
            "transaction": {"signatures": [signature],
                            "message": {"accountKeys": keys, "instructions": instructions or []}}}


def sys_transfer(src, dst, lamports):
    return {"program": "system", "programId": "11111111111111111111111111111111",
            "parsed": {"type": "transfer", "info": {"source": src, "destination": dst, "lamports": lamports}}}


def spl_checked(src, dst, amount, decimals, authority):
    return {"program": "spl-token", "parsed": {"type": "transferChecked", "info": {
        "source": src, "destination": dst, "mint": MINT, "authority": authority,
        "tokenAmount": {"amount": str(amount), "decimals": decimals}}}}


def ok(result):
    return json.dumps({"jsonrpc": "2.0", "id": 1, "result": result}).encode()


class RpcNet:
    """Answers by JSON-RPC method and first param; ``faults`` are served first."""

    def __init__(self, clock, sigs=None, txs=None, faults=None):
        self.clock, self.sigs, self.txs = clock, sigs or {}, txs or {}
        self.faults = faults or []
        self.requests = []

    def __call__(self, req, timeout):
        self.clock[0] += 100
        body = json.loads(req.data.decode())
        self.requests.append(body)
        if self.faults:
            f = self.faults.pop(0)
            if isinstance(f, Exception):
                raise f
            return _Resp(f)
        if body["method"] == "getSignaturesForAddress":
            opts = body["params"][1]
            rows = self.sigs.get(body["params"][0], [])
            if "before" in opts:
                rows = rows[[r["signature"] for r in rows].index(opts["before"]) + 1:]
            return _Resp(ok(rows[: opts["limit"]]))
        return _Resp(ok(self.txs.get(body["params"][0])))


def fetcher(tmp_path, net, clock, display=None):
    c = HttpClient("https://rpc.example/secret-key-abc", TokenBucket(1e6, 1000, clock=lambda: 0.0, sleep=lambda s: None),
                   {}, max_retries=1, sleep=lambda s: None, opener=net, breaker=CircuitBreaker(50, 1, clock=lambda: 0.0),
                   now_ms=lambda: clock[0])
    raw = RawStore(tmp_path)
    return acquire.Fetcher(raw, {rpc.NAME: c}, lambda: clock[0], display={rpc.NAME: rpc.display_base(c.base_url)}
                           if display is None else display), raw


def collect(tmp_path, sigs, txs, faults=None, **kw):
    clock = [T0]
    net = RpcNet(clock, {WALLET: sigs}, txs, faults)
    f, raw = fetcher(tmp_path, net, clock)
    summary = acquire.collect_address_history(f, WALLET, {"chain": "solana", "token": MINT}, **kw)
    obs, issues = normalize_phase3a(str(tmp_path))
    return summary, obs, issues, raw, net


def sig_rows(n, start=0):
    return [{"signature": sig(i), "slot": 300_000_000 - i, "blockTime": 1_789_999_000 - i, "err": None}
            for i in range(start, start + n)]


def test_valid_native_and_token_transfer(tmp_path):
    t = tx(sig(0), instructions=[sys_transfer(FUNDER, WALLET, 1_500_000_000)],
           inner=[{"index": 0, "instructions": [spl_checked(ATA_F, ATA_W, 2_500_000, 6, FUNDER)]}],
           balances=[{"accountIndex": 1, "mint": MINT, "owner": WALLET, "uiTokenAmount": {"amount": "1", "decimals": 6}}])
    t["transaction"]["message"]["accountKeys"][1] = {"pubkey": ATA_W, "signer": False, "writable": True}
    _, obs, issues, _, _ = collect(tmp_path, sig_rows(1), {sig(0): t})
    assert [o.state for o in obs] == [A.OBSERVED, A.OBSERVED]
    native, token = sorted(obs, key=lambda o: o.value["native"], reverse=True)
    assert native.value["amount"] == "1.5" and native.value["amount_raw"] == "1500000000"
    assert native.value["mint"] is None and native.value["mint_state"] == "NOT_APPLICABLE"
    assert native.value["direction"] == "in" and native.value["tx_status"] == "success"
    assert native.source_ts == 1_789_999_000_000 and native.slot == 300_000_000 and native.signature == sig(0)
    assert native.ingestion_ts > native.source_ts and native.raw_id
    assert token.value["mint"] == MINT and token.value["amount"] == "2.5"
    assert token.value["destination_owner"] == WALLET and token.value["inner_index"] == 0
    # ATA_F has no reported balance, so its owner is unknown, not guessed
    assert token.value["source_owner"] is None and token.value["source_owner_state"] == "NOT_OBSERVED"
    assert not issues


def test_signer_is_not_beneficiary(tmp_path):
    t = tx(sig(0), signer=RELAYER, instructions=[sys_transfer(FUNDER, WALLET, 10)])
    _, obs, _, _, _ = collect(tmp_path, sig_rows(1), {sig(0): t})
    v = obs[0].value
    assert v["signers"] == [RELAYER] and v["fee_payer"] == RELAYER and v["source"] == FUNDER
    assert v["beneficiary"] is None and v["beneficiary_status"] == "UNKNOWN"


def test_failed_transaction_kept_with_status(tmp_path):
    t = tx(sig(0), err={"InstructionError": [0, "Custom"]}, instructions=[sys_transfer(FUNDER, WALLET, 10)])
    _, obs, _, _, _ = collect(tmp_path, sig_rows(1), {sig(0): t})
    assert obs[0].state == A.OBSERVED and obs[0].value["tx_status"] == "failed"
    assert "InstructionError" in obs[0].value["tx_err"]


def test_missing_block_time_is_not_replaced_by_ingestion_time(tmp_path):
    t = tx(sig(0), block_time=None, instructions=[sys_transfer(FUNDER, WALLET, 10)])
    _, obs, _, _, _ = collect(tmp_path, sig_rows(1), {sig(0): t})
    o = obs[0]
    assert o.source_ts is None and o.source_ts_state == A.NOT_OBSERVED
    assert o.state == A.OBSERVED  # the transfer itself was observed


def test_no_transfer_touching_wallet_is_not_observed(tmp_path):
    t = tx(sig(0), instructions=[sys_transfer(FUNDER, OTHER, 10)])
    _, obs, _, _, _ = collect(tmp_path, sig_rows(1), {sig(0): t})
    assert [o.state for o in obs] == [A.NOT_OBSERVED] and obs[0].value == {} and obs[0].reason


@pytest.mark.parametrize("body,needle", [
    (b"<html>gateway</html>", "malformed RPC body"),
    (json.dumps({"jsonrpc": "2.0", "id": 1}).encode(), "no result or error"),
    (json.dumps({"jsonrpc": "2.0", "id": 1, "result": {"slot": 1}}).encode(), "malformed transaction"),
])
def test_malformed_rpc_is_error_not_absence(tmp_path, body, needle):
    clock = [T0]
    net = RpcNet(clock, {WALLET: sig_rows(1)}, {})
    f, raw = fetcher(tmp_path, net, clock)
    acquire.collect_address_history(f, WALLET, {}, max_pages=1)
    e = raw.record(provider=rpc.NAME, endpoint="rpc.transaction", url="u", request_ts=T0, response_ts=T0 + 5,
                   status=200, body=body, attempts=1, error=None, context={"address": WALLET, "signature": sig(9)})
    p = rpc.parse_transaction(e, body)
    assert [o.state for o in p.observations] == [A.ERROR] and needle in p.observations[0].reason
    assert p.observations[0].value == {}


def test_rpc_error_object_is_provider_error(tmp_path):
    err = json.dumps({"jsonrpc": "2.0", "id": 1, "error": {"code": -32005, "message": "Node is behind"}}).encode()
    summary, obs, issues, _, _ = collect(tmp_path, sig_rows(1), {}, faults=[err])
    assert obs[0].state == A.ERROR and "-32005" in obs[0].reason
    assert summary["pagination_gap"] == "page 0 failed"
    assert any(i.code == "PROVIDER_ERROR" for i in issues)


def test_provider_timeout_recorded_with_attempts(tmp_path):
    summary, obs, _, raw, _ = collect(tmp_path, sig_rows(1), {}, faults=[TimeoutError("t"), TimeoutError("t")])
    assert obs[0].state == A.ERROR and "request failed" in obs[0].reason
    e = [x for x in raw.entries() if x.endpoint == "rpc.signatures"][0]
    assert len(e.attempt_log) == 2 and e.method == "POST" and e.request_body_sha256
    assert summary["signatures"] == 0


def test_http_error_recorded(tmp_path):
    _, obs, _, _, _ = collect(tmp_path, sig_rows(1), {}, faults=[urllib.error.HTTPError("u", 403, "x", {}, None)])
    assert obs[0].state == A.ERROR and "HTTP 403" in obs[0].reason


def test_pagination_and_bounds(tmp_path):
    rows = sig_rows(7)
    txs = {r["signature"]: tx(r["signature"], instructions=[sys_transfer(FUNDER, WALLET, 1 + i)]) for i, r in enumerate(rows)}
    summary, obs, _, _, net = collect(tmp_path, rows, txs, page_limit=3, max_pages=2, max_txs=5)
    befores = [r["params"][1].get("before") for r in net.requests if r["method"] == "getSignaturesForAddress"]
    assert befores == [None, sig(2)]
    assert summary["signatures"] == 6 and summary["history_truncated"] is True
    assert summary["signatures_not_fetched"] == 1 and len(obs) == 5


def test_duplicate_transaction_deduplicated(tmp_path):
    rows = sig_rows(1)
    t = tx(sig(0), instructions=[sys_transfer(FUNDER, WALLET, 10)])
    clock = [T0]
    net = RpcNet(clock, {WALLET: rows}, {sig(0): t})
    f, _ = fetcher(tmp_path, net, clock)
    acquire.collect_address_history(f, WALLET, {})
    acquire.collect_address_history(f, WALLET, {})  # second pass fetches the same transaction again
    obs, issues = normalize_phase3a(str(tmp_path))
    assert len(obs) == 1 and [i.code for i in issues] == ["DUPLICATE_OBSERVATION"]
    first_ingest = min(e.response_ts for e in RawStore(tmp_path).entries() if e.endpoint == "rpc.transaction")
    assert obs[0].ingestion_ts == first_ingest


def test_two_identical_transfers_in_one_tx_are_not_duplicates(tmp_path):
    t = tx(sig(0), instructions=[sys_transfer(FUNDER, WALLET, 10), sys_transfer(FUNDER, WALLET, 10)])
    _, obs, issues, _, _ = collect(tmp_path, sig_rows(1), {sig(0): t})
    assert len(obs) == 2 and not issues


def test_replay_is_byte_identical(tmp_path):
    rows = sig_rows(3)
    txs = {r["signature"]: tx(r["signature"], instructions=[sys_transfer(FUNDER, WALLET, 5)]) for r in rows}
    collect(tmp_path, rows, txs)
    a, _ = normalize_phase3a(str(tmp_path))
    b, _ = normalize_phase3a(str(tmp_path))
    assert observations_sha256(a) == observations_sha256(b)
    p = tmp_path / "obs.jsonl"
    EventStore.dump_jsonl(p, a)
    back = EventStore.load_jsonl(p)
    order = lambda xs: sorted(xs, key=lambda o: (o.observation_ts, o.ingestion_ts, str(o.signature)))
    assert observations_sha256(back.view(10**15).observations("funding_transfer")) == observations_sha256(order(a))


def test_point_in_time_cutoff_uses_ingestion_not_block_time(tmp_path):
    t = tx(sig(0), instructions=[sys_transfer(FUNDER, WALLET, 10)])
    _, obs, _, _, _ = collect(tmp_path, sig_rows(1), {sig(0): t})
    o = obs[0]
    s = EventStore()
    s.extend(obs)
    assert o.source_ts < o.ingestion_ts
    # at a moment after the block but before we received it, the transfer must be invisible
    assert s.view(o.source_ts + 1).observations("funding_transfer") == []
    assert s.view(o.ingestion_ts - 1).observations("funding_transfer") == []
    assert s.view(o.ingestion_ts).observations("funding_transfer") == [o]


def test_private_rpc_url_never_archived(tmp_path):
    _, _, _, raw, _ = collect(tmp_path, sig_rows(1), {})
    text = (tmp_path / "manifest.jsonl").read_text()
    assert "secret-key-abc" not in text and "rpc.example/<redacted>" in text
    assert rpc.display_base(rpc.PUBLIC_BASE) == rpc.PUBLIC_BASE


def test_every_observation_satisfies_contract(tmp_path):
    t = tx(sig(0), err={"x": 1}, block_time=None, instructions=[sys_transfer(FUNDER, WALLET, 10)])
    _, obs, _, _, _ = collect(tmp_path, sig_rows(2), {sig(0): t})
    for o in obs:
        validate(o)
    assert {o.state for o in obs} == {A.OBSERVED, A.NOT_OBSERVED}  # sig(1) -> RPC null
