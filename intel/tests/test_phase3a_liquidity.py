"""Liquidity-event coverage: vault-delta classification, provider pool creation,
and future-state leakage."""
import json

from autopsyx.core.observation import Availability as A
from autopsyx.data import acquire
from autopsyx.data.normalize3a import normalize_phase3a, observations_sha256
from autopsyx.data.raw import RawStore
from autopsyx.providers.store import EventStore

from phase2_fakes import T_FIX, fixture
from test_phase3a_funding import MINT, RpcNet, T0, addr, fetcher, sig, tx

POOL, QUOTE, VB, VQ = addr(20), addr(21), addr(22), addr(23)
WSOL = "So11111111111111111111111111111111111111112"


def vault_tx(signature, pre, post, err=None, owner=POOL):
    """pre/post: (base_raw, quote_raw) or None when the vault did not exist yet."""
    t = tx(signature, err=err)
    keys = t["transaction"]["message"]["accountKeys"]
    keys += [{"pubkey": VB, "signer": False, "writable": True}, {"pubkey": VQ, "signer": False, "writable": True}]

    def bals(x):
        if x is None:
            return []
        return [{"accountIndex": 2, "mint": MINT, "owner": owner, "uiTokenAmount": {"amount": str(x[0]), "decimals": 6}},
                {"accountIndex": 3, "mint": WSOL, "owner": owner, "uiTokenAmount": {"amount": str(x[1]), "decimals": 9}}]
    t["meta"]["preTokenBalances"], t["meta"]["postTokenBalances"] = bals(pre), bals(post)
    return t


def run(tmp_path, txs):
    rows = [{"signature": t["transaction"]["signatures"][0], "slot": t["slot"], "blockTime": t["blockTime"], "err": None}
            for t in txs]
    clock = [T0]
    net = RpcNet(clock, {POOL: rows}, {r["signature"]: t for r, t in zip(rows, txs)})
    f, raw = fetcher(tmp_path, net, clock)
    acquire.collect_address_history(f, POOL, {"chain": "solana", "pool": POOL, "token": MINT, "dex": "pumpswap"},
                                    purpose="liquidity")
    return normalize_phase3a(str(tmp_path))


def kinds(obs):
    return [(o.state.value, o.value.get("event_type")) for o in obs]


def test_add_remove_create_and_swap(tmp_path):
    obs, _ = run(tmp_path, [vault_tx(sig(0), None, (1000, 50)),         # creation with initial liquidity
                            vault_tx(sig(1), (1000, 50), (1200, 60)),    # add
                            vault_tx(sig(2), (1200, 60), (900, 45)),     # remove
                            vault_tx(sig(3), (900, 45), (800, 50))])     # swap
    by_sig = {o.signature: o for o in obs}
    assert by_sig[sig(0)].value["event_type"] == "pool_create"
    assert by_sig[sig(1)].value["event_type"] == "add"
    assert by_sig[sig(1)].value["base_amount_raw"] == "200" and by_sig[sig(1)].value["quote_amount_raw"] == "10"
    assert by_sig[sig(2)].value["event_type"] == "remove" and by_sig[sig(2)].value["base_amount_raw"] == "-300"
    assert by_sig[sig(3)].state == A.NOT_OBSERVED and "swap" in by_sig[sig(3)].reason
    o = by_sig[sig(1)]
    assert o.entity == POOL and o.venue == "pumpswap" and o.slot and o.source_ts and o.ingestion_ts > o.source_ts
    assert o.value["quote_mint"] == WSOL and o.value["classification_method"] == "vault_balance_delta"
    assert {d["vault"] for d in o.value["vault_deltas"]} == {VB, VQ}


def test_vault_authority_elsewhere_is_coverage_gap_not_absence(tmp_path):
    obs, _ = run(tmp_path, [vault_tx(sig(0), (1, 1), (2, 2), owner=addr(30))])
    assert obs[0].state == A.NOT_OBSERVED and "vault authority" in obs[0].reason and obs[0].value == {}


def test_failed_transaction_is_not_a_liquidity_event(tmp_path):
    obs, _ = run(tmp_path, [vault_tx(sig(0), (1, 1), (1, 1), err={"x": 1})])
    assert obs[0].state == A.NOT_OBSERVED and "failed" in obs[0].reason


def test_rpc_failure_is_liquidity_error(tmp_path):
    clock = [T0]
    net = RpcNet(clock, {}, {}, faults=[TimeoutError("t"), TimeoutError("t")])
    f, _ = fetcher(tmp_path, net, clock)
    acquire.collect_address_history(f, POOL, {"pool": POOL, "token": MINT}, purpose="liquidity")
    obs, _ = normalize_phase3a(str(tmp_path))
    assert [(o.kind, o.state) for o in obs] == [("liquidity_event", A.ERROR)]


def _gt_pools_run(tmp_path, response_ts):
    raw = RawStore(tmp_path)
    raw.record(provider="geckoterminal", endpoint="gt.new_pools", url="u", request_ts=response_ts - 100,
               response_ts=response_ts, status=200, body=fixture("gt_pools.json"), attempts=1, error=None,
               context={"chain": "solana", "page": 1})
    return raw


def test_provider_pool_creation_claims_no_amounts(tmp_path):
    _gt_pools_run(tmp_path, T_FIX)
    obs, _ = normalize_phase3a(str(tmp_path))
    assert obs and all(o.value["event_type"] == "pool_create" for o in obs)
    for o in obs:
        assert o.value["base_amount_raw"] is None and o.value["base_amount_raw_state"] == "NOT_OBSERVED"
        assert o.value["vault_deltas"] is None and o.source_ts <= o.ingestion_ts
        assert o.value["classification_method"] == "provider_metadata:pool_created_at"


def test_no_liquidity_history_from_current_state(tmp_path):
    """A pool list response is current state. It may say when the pool was
    created; it must never yield add/remove history, and nothing it says is
    visible before the response arrived, however old the creation time."""
    _gt_pools_run(tmp_path, T_FIX)
    obs, _ = normalize_phase3a(str(tmp_path))
    assert {o.value["event_type"] for o in obs} == {"pool_create"}
    s = EventStore()
    s.extend(obs)
    earliest_created = min(o.source_ts for o in obs)
    assert s.view(earliest_created).observations("liquidity_event") == []
    assert s.view(T_FIX - 1).observations("liquidity_event") == []
    assert len(s.view(T_FIX).observations("liquidity_event")) == len(obs)


def test_later_fetch_does_not_rewrite_earlier_view(tmp_path):
    """Leakage regression: an event fetched later (even with an earlier block
    time) must not appear in a view cut before that fetch."""
    obs1, _ = run(tmp_path / "a", [vault_tx(sig(1), (1000, 50), (1200, 60))])
    cut = max(o.ingestion_ts for o in obs1)
    before = observations_sha256(EventStore().view(0).observations("liquidity_event"))
    s = EventStore()
    s.extend(obs1)
    snap = observations_sha256(s.view(cut).observations("liquidity_event"))
    late = [o.__class__(**{**o.__dict__, "ingestion_ts": cut + 60_000}) for o in
            run(tmp_path / "b", [vault_tx(sig(2), (1200, 60), (900, 45))])[0]]
    assert all(o.source_ts < cut for o in late)
    s.extend(late)
    assert observations_sha256(s.view(cut).observations("liquidity_event")) == snap != before
    assert len(s.view(cut + 60_000).observations("liquidity_event")) == 2


def test_liquidity_replay_deterministic(tmp_path):
    run(tmp_path, [vault_tx(sig(0), None, (1000, 50)), vault_tx(sig(1), (1000, 50), (1200, 60))])
    a, _ = normalize_phase3a(str(tmp_path))
    b, _ = normalize_phase3a(str(tmp_path))
    assert observations_sha256(a) == observations_sha256(b)
    assert json.dumps([o.to_dict() for o in a], sort_keys=True) == json.dumps([o.to_dict() for o in b], sort_keys=True)
