from types import SimpleNamespace

from autopsyx.research.phase3d_data_audit import _liquidity_join_diagnostics


def bar(ts, *, token="mint", pool="pool-a", chain="solana"):
    return SimpleNamespace(
        ts=ts, seen_ts=ts + 1, token=token, pool=pool, chain=chain,
        open=1.0, high=1.1, low=0.9, close=1.0,
    )


def snapshot(ts, seen_ts, *, liquidity=1000.0, token="mint", pool="pool-a", chain="solana"):
    return SimpleNamespace(
        ts=ts, seen_ts=seen_ts, token=token, pool=pool, chain=chain,
        liquidity_usd=liquidity,
    )


def test_join_diagnostics_separate_ingestion_and_staleness_failures():
    report = _liquidity_join_diagnostics(
        [bar(0), bar(60_000), bar(120_000)],
        [
            snapshot(0, 1),
            snapshot(60_000, 60_000),
        ],
        chain="solana",
        token="mint",
        pool="pool-a",
        max_liquidity_age_ms=30_000,
    )

    assert report["bar_count"] == 3
    assert report["matching_snapshot_count"] == 2
    assert report["bars_with_eligible_snapshot"] == 1
    assert report["bars_without_eligible_snapshot"] == 2
    assert report["unmatched_bar_reasons"]["not_ingested_by_bar_open"] == 1
    assert report["unmatched_bar_reasons"]["stale_snapshot"] == 1


def test_join_diagnostics_identify_missing_identity_match():
    report = _liquidity_join_diagnostics(
        [bar(60_000)],
        [snapshot(60_000, 60_000, pool="different-pool")],
        chain="solana",
        token="mint",
        pool="pool-a",
        max_liquidity_age_ms=60_000,
    )

    assert report["matching_snapshot_count"] == 0
    assert report["unmatched_bar_reasons"]["no_matching_snapshot"] == 1
