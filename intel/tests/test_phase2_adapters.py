"""Adapter, validation, raw-archive, pagination, retry, duplicate and conflict tests (Phase 2)."""
import gzip
import json
import urllib.error

import pytest

from autopsyx.core.models import Coverage, HolderSnapshot, PoolInfo, PoolSnapshot, ProviderBar, Side, Swap, TokenMeta
from autopsyx.data import acquire
from autopsyx.data.normalize import coverage_gaps, normalize
from autopsyx.data.providers import dexscreener as ds
from autopsyx.data.providers import geckoterminal as gt
from autopsyx.data.raw import ManifestEntry, RawStore, sha256
from autopsyx.data.validate import Code, check_ts, iso_ms, num, valid_address

from phase2_fakes import T_FIX, fixture, http_error, run_fake


def entry(endpoint="gt.trades", response_ts=T_FIX, **ctx):
    base = {"chain": "solana", "pool": "HCikAJCwxbpfE6jGMiGaKQQv9vUkoBpTq5AV9gPnzKPg",
            "token": "9sJZFixcrP4WVTXmQ4Rmkbr1LTk9Em5v5A7Y82jtpump"}
    return ManifestEntry(1, "geckoterminal", endpoint, "u", response_ts - 100, response_ts, 200, "rid", 1, 1, None,
                         base | ctx)


def codes(parsed):
    return [i.code for i in parsed.issues]


def of(parsed, cls):
    return [r for r in parsed.records if isinstance(r, cls)]


# ------------------------------------------------------------------ parsing real payloads ----
def test_pools_parse_real_payload():
    p = gt.parse_pools(entry("gt.new_pools"), fixture("gt_pools.json"))
    infos, snaps, metas = of(p, PoolInfo), of(p, PoolSnapshot), of(p, TokenMeta)
    assert len(infos) == 3 and len(snaps) == 3
    stonk = next(s for s in snaps if s.pool.startswith("HCik"))
    assert stonk.liquidity_usd == pytest.approx(54548.7643) and stonk.source == "geckoterminal"
    assert stonk.raw_id == "rid" and stonk.ts == stonk.seen_ts == T_FIX
    zero = next(s for s in snaps if s.pool.startswith("4EQ5"))
    assert zero.liquidity_usd == 0.0  # provider-reported zero is kept as zero, not treated as missing
    assert {i.amm_model for i in infos} == {"cpmm", "unknown"}
    assert Code.DERIVED_FIELD in codes(p)  # total supply derived from fdv / price, and said so
    assert all(m.total_supply and m.total_supply > 0 for m in metas)


def test_trades_parse_real_payload():
    p = gt.parse_trades(entry(), fixture("gt_trades.json"), lag_ms=60_000)
    swaps = of(p, Swap)
    assert len(swaps) == 2
    sell = next(s for s in swaps if s.side == Side.SELL)
    assert sell.wallet == "9R3m89gXeC6BWc2aN9CFqWDZA5WUJP3umQUerC7gjoFs"
    assert sell.token_amount == 40_000_000.0 and sell.block == 451902423 and sell.log_index == 40
    assert sell.ts == iso_ms("2026-09-30T07:51:26Z") and sell.seen_ts == T_FIX
    cov = of(p, Coverage)[0]
    # fewer than a full page: all trades of the last 24 h were returned
    assert cov.start_ts == T_FIX - 86_400_000 and cov.end_ts == T_FIX - 60_000


def test_full_trade_page_limits_coverage():
    doc = json.loads(fixture("gt_trades.json"))
    doc["data"] = doc["data"] * 150  # 300 rows
    p = gt.parse_trades(entry(), json.dumps(doc).encode(), 60_000)
    cov = of(p, Coverage)[0]
    assert Code.PAGE_FULL in codes(p)
    assert cov.start_ts == min(s.ts for s in of(p, Swap))


def test_ohlcv_drops_forming_bar_and_claims_coverage():
    # response 30 s after the newest bar opened: that bar is still forming
    resp = 1790754660000 + 30_000
    p = gt.parse_ohlcv(entry("gt.ohlcv", response_ts=resp, token="Aju3ZDM4FxFory2oUTkBGMoV2aomjLGXsAuivnEz2Qpu"),
                       fixture("gt_ohlcv.json"), lag_ms=0)
    bars = of(p, ProviderBar)
    assert [b.ts for b in bars] == [1790754600000, 1790754540000]
    assert Code.FORMING_BAR_DROPPED in codes(p)
    cov = of(p, Coverage)[0]
    assert cov.kind == "bars" and cov.end_ts <= resp and cov.start_ts == 1790754540000


def test_token_info_holders():
    p = gt.parse_token_info(entry("gt.token_info", token="Aju3ZDM4FxFory2oUTkBGMoV2aomjLGXsAuivnEz2Qpu"),
                            fixture("gt_token_info.json"))
    h = of(p, HolderSnapshot)[0]
    assert h.holders == 512 and h.top10_pct == pytest.approx(0.691764)
    assert h.creator_pct is None  # developer_holding_percentage is null: unknown, not zero
    assert h.ts == iso_ms("2026-09-30T07:50:36Z")


def test_dexscreener_pairs():
    e = entry("ds.pairs", pool_tokens={"DVeKcCRSDYXbPE4gAJQeabXhg6zLZPDtTF1qkTs6sRHS":
                                       "Aju3ZDM4FxFory2oUTkBGMoV2aomjLGXsAuivnEz2Qpu"})
    p = ds.parse_pairs(e, fixture("ds_pairs.json"))
    s = of(p, PoolSnapshot)[0]
    assert s.source == "dexscreener" and s.liquidity_usd == pytest.approx(40297.88) and s.price_usd == pytest.approx(4.019e-5)


# ------------------------------------------------------------------------ bad payloads ----
def mutate_trade(**changes):
    doc = json.loads(fixture("gt_trades.json"))
    doc["data"] = doc["data"][:1]
    doc["data"][0]["attributes"].update(changes)
    return json.dumps(doc).encode()


@pytest.mark.parametrize("changes,code", [
    ({"block_timestamp": "2027-01-01T00:00:00Z"}, Code.IMPOSSIBLE_TIMESTAMP),
    ({"block_timestamp": "2026-09-30T07:51:26"}, Code.IMPOSSIBLE_TIMESTAMP),  # no zone: undefined meaning
    ({"block_timestamp": "2001-01-01T00:00:00Z"}, Code.IMPOSSIBLE_TIMESTAMP),
    ({"price_from_in_usd": "-1"}, Code.NEGATIVE_PRICE),
    ({"volume_in_usd": "-5"}, Code.NEGATIVE_VOLUME),
    ({"tx_from_address": "not-a-wallet"}, Code.MALFORMED_ADDRESS),
    ({"from_token_address": "So11111111111111111111111111111111111111112"}, Code.TOKEN_PAIR_MISMATCH),
    ({"kind": "swap"}, Code.MALFORMED_RECORD),
    ({"volume_in_usd": None}, Code.NULL_FIELD),
])
def test_bad_trade_fields_are_dropped_and_reported(changes, code):
    p = gt.parse_trades(entry(), mutate_trade(**changes), 60_000)
    assert of(p, Swap) == []
    assert code in codes(p)


def test_malformed_and_partial_responses():
    assert Code.MALFORMED_RECORD in codes(gt.parse_trades(entry(), b"<html>rate limited</html>", 0))
    assert Code.PARTIAL_RESPONSE in codes(gt.parse_trades(entry(), b'{"errors":[{"status":"429"}]}', 0))
    assert Code.PARTIAL_RESPONSE in codes(ds.parse_pairs(entry("ds.pairs"), b'{"schemaVersion":"1.0.0"}'))


def test_pool_validation():
    doc = json.loads(fixture("gt_pools.json"))
    doc["data"][0]["attributes"]["reserve_in_usd"] = "-10"
    doc["data"][1]["id"] = "eth_DVeKcCRSDYXbPE4gAJQeabXhg6zLZPDtTF1qkTs6sRHS"
    doc["data"][2]["attributes"]["transactions"]["h1"]["buys"] = -3
    p = gt.parse_pools(entry("gt.new_pools"), json.dumps(doc).encode())
    assert {Code.NEGATIVE_LIQUIDITY, Code.CHAIN_MISMATCH, Code.IMPOSSIBLE_COUNT} <= set(codes(p))
    assert len(of(p, PoolSnapshot)) == 1


def test_impossible_ohlc_rejected():
    doc = json.loads(fixture("gt_ohlcv.json"))
    doc["data"]["attributes"]["ohlcv_list"][1][2] = 1e-9  # high below low
    p = gt.parse_ohlcv(entry("gt.ohlcv", token="Aju3ZDM4FxFory2oUTkBGMoV2aomjLGXsAuivnEz2Qpu"), json.dumps(doc).encode(), 0)
    assert Code.IMPOSSIBLE_OHLC in codes(p)


def test_dexscreener_chain_and_pair_conflicts():
    doc = json.loads(fixture("ds_pairs.json"))
    pool = doc["pairs"][0]["pairAddress"]
    p = ds.parse_pairs(entry("ds.pairs", pool_tokens={pool: "9sJZFixcrP4WVTXmQ4Rmkbr1LTk9Em5v5A7Y82jtpump"}),
                       json.dumps(doc).encode())
    assert Code.CONFLICTING_METADATA in codes(p) and not of(p, PoolSnapshot)
    doc["pairs"][0]["chainId"] = "base"
    p = ds.parse_pairs(entry("ds.pairs"), json.dumps(doc).encode())
    assert Code.CHAIN_MISMATCH in codes(p)


# ------------------------------------------------------------------ missing vs zero ----
def test_missing_is_never_zero():
    for v in (None, "", "n/a", float("nan"), float("inf"), True):
        assert num(v) is None
    assert num("0") == 0.0 and num("0E-9") == 0.0
    assert iso_ms(None) is None and iso_ms("garbage") is None
    assert check_ts(None, 1, 0) is not None


def test_address_validation():
    assert valid_address("solana", "So11111111111111111111111111111111111111112")
    assert not valid_address("solana", "0O0O0O0O0O0O0O0O0O0O0O0O0O0O0O0O")  # 0/O not base58
    assert valid_address("base", "0x" + "ab" * 20) and not valid_address("base", "0x123")


# ------------------------------------------------------------------ raw archive ----
def test_raw_store_preserves_bytes_and_detects_corruption(tmp_path):
    rs = RawStore(tmp_path)
    body = fixture("gt_trades.json")
    e = rs.record(provider="geckoterminal", endpoint="gt.trades", url="u", request_ts=1, response_ts=2, status=200,
                  body=body, attempts=1, error=None)
    assert e.raw_id == sha256(body) and rs.body(e.raw_id) == body
    err = rs.record(provider="geckoterminal", endpoint="gt.trades", url="u", request_ts=3, response_ts=None,
                    status=None, body=None, attempts=None, error="timeout")
    assert err.raw_id is None and [x.seq for x in rs.entries()] == [1, 2]
    (tmp_path / "raw" / f"{e.raw_id}.json.gz").write_bytes(gzip.compress(b'{"data":[]}', mtime=0))
    with pytest.raises(ValueError):
        rs.body(e.raw_id)


def test_every_normalized_record_traces_to_raw(tmp_path):
    run_fake(tmp_path, cycles=2)
    records, rep = normalize(str(tmp_path))
    raw_ids = {e.raw_id for e in RawStore(tmp_path).entries() if e.raw_id}
    assert records
    for r in records:
        assert r.source in ("geckoterminal", "dexscreener")
        assert r.raw_id in raw_ids


def test_normalization_is_deterministic(tmp_path):
    run_fake(tmp_path, cycles=2)
    a = normalize(str(tmp_path))[1].dataset_sha256
    b = normalize(str(tmp_path))[1].dataset_sha256
    assert a == b


# ------------------------------------------------------ provider failure / retry / pagination ----
def test_rate_limit_is_retried_and_recorded(tmp_path):
    meta, net = run_fake(tmp_path, cycles=1, faults={"/trades": [http_error(429)]})
    trades = [e for e in RawStore(tmp_path).entries() if e.endpoint == "gt.trades"]
    assert trades[0].attempts == 2 and trades[0].error is None
    assert meta["status"] == "COMPLETE"


def test_timeouts_exhausting_retries_are_recorded_and_run_continues(tmp_path):
    meta, net = run_fake(tmp_path, cycles=2, faults={"/trades": [TimeoutError("t")] * 3})
    entries = RawStore(tmp_path).entries()
    failed = [e for e in entries if e.endpoint == "gt.trades" and e.error]
    assert failed and "exhausted retries" in failed[0].error
    assert meta["cycles"] == 2  # an outage on one endpoint does not stop collection
    _, rep = normalize(str(tmp_path))
    assert rep.provider_errors >= 1 and rep.issues.get(Code.PROVIDER_ERROR)


def test_pagination_gap_recorded_and_later_pages_used(tmp_path):
    plan = acquire.Plan(strata={"young": 3, "quiet_young": 0, "trending": 0, "established": 0}, new_pool_pages=3,
                        backfill_pages=1, cycle_s=60, duration_s=10_000)
    faults = {"new_pools?page=2": [http_error(404)]}
    run_fake(tmp_path, cycles=0, faults=faults, plan=plan)
    entries = RawStore(tmp_path).entries()
    assert any(e.endpoint == "pagination_gap" for e in entries)
    assert sum(1 for e in entries if e.endpoint == "gt.new_pools" and e.raw_id) == 2
    _, rep = normalize(str(tmp_path))
    assert rep.issues.get(Code.PAGINATION_GAP) == 1


def test_partial_api_response_is_reported(tmp_path):
    run_fake(tmp_path, cycles=1, faults={"/trades": [b'{"errors":[{"title":"partial"}]}']})
    _, rep = normalize(str(tmp_path))
    assert rep.issues.get(Code.PARTIAL_RESPONSE)


def test_duplicate_observations_counted_not_dropped_silently(tmp_path):
    run_fake(tmp_path, cycles=3)
    records, rep = normalize(str(tmp_path))
    assert rep.duplicate_swaps > 0 and rep.issues.get(Code.DUPLICATE_OBSERVATION) == 1


def test_selection_is_seeded_and_recorded(tmp_path):
    run_fake(tmp_path / "a", cycles=0)
    run_fake(tmp_path / "b", cycles=0)
    sa = json.loads((tmp_path / "a" / "selection.json").read_text())
    sb = json.loads((tmp_path / "b" / "selection.json").read_text())
    assert sa["seed"] == sb["seed"] and sa["picked"] == sb["picked"]
    assert "Strata" in sa["procedure"]


def test_coverage_gaps():
    mk = lambda a, b: Coverage("solana", "t", "p", "trades", a, b, b)
    assert coverage_gaps([mk(0, 10), mk(5, 20), mk(30, 40)], 0, 40) == [(20, 30)]
    assert coverage_gaps([mk(0, 40)], 0, 40) == []


def test_acquire_cli_refuses_without_live_flag(tmp_path):
    from autopsyx.__main__ import main
    req = tmp_path / "r.json"
    req.write_text("{}")
    assert main(["acquire", "--request", str(req), "--out", str(tmp_path / "o")]) == 2
    assert not (tmp_path / "o").exists()


def test_adaptive_rate_halves_on_429_and_recovers():
    """Regression (archive gt-sol-20260930a): a shared CI IP was throttled below the published limit."""
    from autopsyx.providers.http import CircuitBreaker, HttpClient, TokenBucket
    from phase2_fakes import _Resp
    script = [http_error(429), http_error(429), b"{}", b"{}"]

    def opener(req, timeout):
        r = script.pop(0)
        if isinstance(r, Exception):
            raise r
        return _Resp(r)
    bucket = TokenBucket(0.4, 5, clock=lambda: 0.0, sleep=lambda s: None)
    c = HttpClient("https://x", bucket, sleep=lambda s: None, opener=opener, max_retries=3,
                   breaker=CircuitBreaker(50, 1), adaptive_min_rate=0.05, adaptive_step=0.01)
    c.get_raw("/a")
    assert bucket.rate == pytest.approx(0.4 * 0.25 + 0.01)
    c.get_raw("/b")
    assert bucket.rate == pytest.approx(0.12)
    for _ in range(3):
        script.append(http_error(429))
    script.append(b"{}")
    c.get_raw("/c")
    assert bucket.rate >= 0.05  # never below the floor


def test_fetcher_waits_out_open_circuit_instead_of_failing(tmp_path):
    """Regression (archive gt-sol-20260930a): queued backfill calls failed instantly against an open circuit."""
    faults = {"/ohlcv/": [http_error(503)] * 3}
    plan = acquire.Plan(strata={"young": 1, "quiet_young": 0, "trending": 0, "established": 0}, new_pool_pages=1,
                        backfill_pages=1, cycle_s=60, duration_s=10_000, circuit_waits=3)
    from phase2_fakes import FakeNet, clients as mk_clients
    clock = [T_FIX]
    net = FakeNet(clock, faults)
    cl = mk_clients(net, clock)
    cl["geckoterminal"].breaker = __import__("autopsyx.providers.http", fromlist=["CircuitBreaker"]).CircuitBreaker(
        threshold=2, cooldown_s=30, clock=lambda: clock[0] / 1000)

    def sleep(s):
        clock[0] += int(s * 1000)
    acquire.run(str(tmp_path), plan, cl, now_ms=lambda: clock[0], sleep=sleep, max_cycles=0)
    ohlcv = [e for e in RawStore(tmp_path).entries() if e.endpoint == "gt.ohlcv"]
    info = [e for e in RawStore(tmp_path).entries() if e.endpoint == "gt.token_info"]
    assert info and info[0].raw_id is not None  # the call after the failures waited and succeeded
    assert json.loads((tmp_path / "run.json").read_text())["circuit_waits"] >= 1


def test_restrict_to_selection_keeps_only_polled_tokens(tmp_path):
    from autopsyx.data.normalize import restrict_to_selection
    run_fake(tmp_path, cycles=1, plan=acquire.Plan(strata={"young": 1, "quiet_young": 0, "trending": 0, "established": 0},
                                                   new_pool_pages=1, backfill_pages=1, duration_s=10_000))
    records, _ = normalize(str(tmp_path))
    sel = json.loads((tmp_path / "selection.json").read_text())
    kept = restrict_to_selection(records, sel)
    toks = {getattr(r, "token", None) or r.ref.address for r in kept}
    assert toks == {p["token"] for p in sel["picked"]} and len(kept) < len(records)
