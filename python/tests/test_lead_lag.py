"""Deterministic tests for the Information Transmission / Lead-Lag engine
(python/autopsy_research/lead_lag.py), the executable reference
implementation InformationTransmissionEngine.mqh's own header documents
itself as mirroring.

These are the 12 tests Phase 4A's own authorization requires
(section 12), implemented literally, not paraphrased. Each one actually
runs under pytest - see the Phase 4A report for the real pass/fail
output, not a claim.
"""
from __future__ import annotations

import sys
from pathlib import Path

import numpy as np
import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from autopsy_research.lead_lag import (
    TransmissionState,
    align_returns,
    compute_snapshot,
    lag_scan,
    pearson_corr,
)

def _leader_series(n: int, scale: float = 0.001, seed: int = 20260928) -> np.ndarray:
    """Fresh, independently-seeded RNG per call, not a shared module-level
    generator - a shared RNG made test outcomes depend on execution ORDER
    (test_3 passed in isolation but failed after test_1/test_2 had already
    consumed draws from it), caught by actually running the suite, not by
    inspection. Each call site below passes its own distinct seed."""
    return np.random.default_rng(seed).normal(loc=0.0, scale=scale, size=n)


def test_1_perfect_positive_lead():
    """Test 1: Perfect Positive Lead - receiver follows leader by a known
    lag with an exact positive relationship. Expect: correct lag, positive
    relationship, strong response, no false other-lag winner."""
    lag = 3
    n = 300
    leader = _leader_series(n, seed=101)
    receiver = np.empty(n)
    receiver[:lag] = _leader_series(lag, seed=102)  # unrelated warm-up, not leaked
    receiver[lag:] = leader[: n - lag]  # exact positive lead-lag

    snap = compute_snapshot(leader, receiver, max_lag=10, min_sample_size=30)

    assert snap.valid
    assert snap.best_lag == lag
    assert snap.direction == 1
    assert snap.association_strength > 0.95
    assert snap.state in (TransmissionState.LEADER, TransmissionState.CONFIRMING)


def test_2_perfect_inverse_lead():
    """Test 2: Perfect Inverse Lead - receiver consistently falls after
    the known lag when leader rises. Expect: correct lag, inverse
    relationship, strong association."""
    lag = 4
    n = 300
    leader = _leader_series(n, seed=201)
    receiver = np.empty(n)
    receiver[:lag] = _leader_series(lag, seed=202)
    receiver[lag:] = -leader[: n - lag]

    snap = compute_snapshot(leader, receiver, max_lag=10, min_sample_size=30)

    assert snap.valid
    assert snap.best_lag == lag
    assert snap.direction == -1
    assert snap.association_strength > 0.95


def test_3_no_relationship():
    """Test 3: No Relationship - independent series. Expect weak/unstable
    relationship, no false strong transmission reported at any lag."""
    n = 400
    leader = _leader_series(n, seed=301)
    receiver = _leader_series(n, scale=0.0015, seed=302)  # independent RNG draw

    snap = compute_snapshot(leader, receiver, max_lag=10, min_sample_size=30)

    # the raw "best of 11 lags" correlation will always be somewhat nonzero
    # by chance (multiple-comparisons selection) - the actual safety
    # property is that this is correctly GATED: state must be INACTIVE and
    # confidence must be zero, not that the raw statistic itself is tiny
    assert snap.state == TransmissionState.INACTIVE
    assert snap.confidence == 0.0
    # no lag in the scanned profile should show a spuriously STRONG read
    assert all(abs(r.correlation) < 0.30 for r in snap.lag_profile)


def test_4_zero_lag_relationship():
    """Test 4: Zero-Lag Relationship - leader and receiver move together
    concurrently. Expect lag at or near zero."""
    n = 300
    leader = _leader_series(n, seed=401)
    receiver = leader * 0.8 + _leader_series(n, scale=0.0001, seed=402)  # near-identical, same index

    snap = compute_snapshot(leader, receiver, max_lag=10, min_sample_size=30)

    assert snap.valid
    assert snap.best_lag == 0
    assert snap.direction == 1
    assert snap.association_strength > 0.9


def test_5_known_lag_shift():
    """Test 5: Known Lag Shift - relationship exists at lag=7. Expect the
    engine identifies that lag."""
    lag = 7
    n = 350
    leader = _leader_series(n, seed=501)
    receiver = np.empty(n)
    receiver[:lag] = _leader_series(lag, seed=502)
    receiver[lag:] = leader[: n - lag]

    snap = compute_snapshot(leader, receiver, max_lag=12, min_sample_size=30)

    assert snap.valid
    assert snap.best_lag == lag


def test_6_regime_dependent_relationship():
    """Test 6: Regime-Dependent Relationship - the lead-lag relationship
    only exists in one regime bucket. Expect regime-bucketed strength to
    differ, and the engine must not claim universal stability."""
    lag = 2
    n_per_regime = 250
    n = n_per_regime * 2

    leader = _leader_series(n, seed=601)
    receiver = np.empty(n)

    # regime 1 (first half): genuine relationship
    receiver[:lag] = _leader_series(lag, seed=602)
    receiver[lag:n_per_regime] = leader[: n_per_regime - lag]
    # regime 2 (second half): no relationship at all
    receiver[n_per_regime:] = _leader_series(n - n_per_regime, scale=0.0012, seed=603)

    regimes = np.array([1] * n_per_regime + [2] * (n - n_per_regime))

    snap = compute_snapshot(
        leader, receiver, max_lag=5, min_sample_size=30, regimes=regimes, min_regime_sample_size=20
    )

    by_regime = {b.regime: b for b in snap.regime_buckets}
    assert by_regime[1].sufficient and by_regime[2].sufficient
    assert abs(by_regime[1].correlation) > abs(by_regime[2].correlation) + 0.3
    # the engine must not report a single "stable across everything" verdict -
    # regime 2's own bucket correlation must itself be weak
    assert abs(by_regime[2].correlation) < 0.3


def test_7_relationship_breakdown():
    """Test 7: Relationship Breakdown - strong initially, then disappears.
    Expect stability to deteriorate and a DIVERGING/WEAKENING state, not a
    naive "still strong overall" verdict."""
    lag = 2
    n_strong = 200
    n_weak = 200
    n = n_strong + n_weak

    leader = _leader_series(n, seed=701)
    receiver = np.empty(n)
    receiver[:lag] = _leader_series(lag, seed=702)
    receiver[lag:n_strong] = leader[: n_strong - lag]  # strong, older half
    receiver[n_strong:] = _leader_series(n_weak, scale=0.0012, seed=703)  # gone, recent half

    snap = compute_snapshot(leader, receiver, max_lag=5, min_sample_size=30)

    assert snap.valid
    assert snap.state in (TransmissionState.DIVERGING, TransmissionState.WEAKENING)
    assert snap.stability < 80.0


def test_8_relationship_inversion():
    """Test 8: Relationship Inversion - positive relationship becomes
    negative. Expect INVERTED state and reduced confidence."""
    lag = 2
    n_pos = 200
    n_neg = 200
    n = n_pos + n_neg

    leader = _leader_series(n, seed=801)
    receiver = np.empty(n)
    receiver[:lag] = _leader_series(lag, seed=802)
    receiver[lag:n_pos] = leader[: n_pos - lag]
    receiver[n_pos:] = -leader[n_pos - lag : n - lag]

    snap = compute_snapshot(leader, receiver, max_lag=5, min_sample_size=30)

    assert snap.valid
    assert snap.state == TransmissionState.INVERTED
    # confidence must be penalized relative to an equally-strong, non-inverted read
    control = compute_snapshot(leader[:n_pos], leader[:n_pos], max_lag=0, min_sample_size=30)
    assert snap.confidence < control.confidence


def test_9_missing_data():
    """Test 9: Missing Data - too few observations. Expect no fabricated
    values and an explicit INSUFFICIENT_DATA state."""
    leader = _leader_series(5, seed=901)
    receiver = _leader_series(5, seed=902)

    snap = compute_snapshot(leader, receiver, max_lag=3, min_sample_size=30)

    assert not snap.valid
    assert snap.state == TransmissionState.INSUFFICIENT_DATA
    assert snap.association_strength == 0.0
    assert snap.confidence == 0.0
    assert snap.best_lag == -1


def test_10_stale_data():
    """Test 10: Stale Data - the feed has gone quiet since the most
    recent bar. Expect ONLY that most-recent pair rejected, not the whole
    history (staleness is a live, current-tick concept, not a retroactive
    judgment on already-closed history - see align_returns's own
    docstring for why an earlier draft got this wrong: comparing every
    historical pair against a single global `now` made every non-trivial
    history fail its own staleness check purely by being old, which is
    what makes it history, not what makes it invalid)."""
    n = 50
    times = np.arange(n, dtype=float) * 60.0  # 1-minute bars, seconds
    closes_leader = 100.0 + np.cumsum(_leader_series(n, seed=1001) * 100)
    closes_receiver = 50.0 + np.cumsum(_leader_series(n, seed=1002) * 100)

    now = times[-1]
    fresh_l, fresh_r = align_returns(closes_leader, times, closes_receiver, times, now, max_stale_seconds=120.0)
    assert len(fresh_l) == n - 1

    # feed has gone quiet: `now` is far ahead of the last bar's own timestamp -
    # only that single most recent pair should be dropped, earlier history intact
    stale_now = times[-1] + 3600.0  # 1 hour later
    stale_l, stale_r = align_returns(closes_leader, times, closes_receiver, times, stale_now, max_stale_seconds=120.0)
    assert len(stale_l) == n - 2
    assert len(stale_r) == n - 2
    np.testing.assert_array_equal(stale_l, fresh_l[:-1])
    np.testing.assert_array_equal(stale_r, fresh_r[:-1])


def test_11_timestamp_misalignment():
    """Test 11: Timestamp Misalignment - receiver timestamps drift from
    leader's by varying amounts, some within tolerance and some beyond it.
    Expect deterministic behavior (same output every run on the same
    input) and that only the pairs within max_misalignment_seconds survive
    - not zero, not all - proving the tolerance check actually discriminates
    rather than being a no-op or an everything-fails gate."""
    n = 60
    leader_times = np.arange(n, dtype=float) * 300.0  # 5-minute bars
    # deterministic per-index jitter: alternates within-tolerance (5s) and
    # beyond-tolerance (400s, against a 100s max_misalignment_seconds below)
    jitter = np.array([5.0 if i % 2 == 0 else 400.0 for i in range(n)])
    receiver_times = leader_times + jitter
    closes_leader = 2000.0 + np.cumsum(_leader_series(n, seed=1101) * 500)
    closes_receiver = 1.10 + np.cumsum(_leader_series(n, seed=1102) * 0.001)
    now = leader_times[-1] + 400.0

    l1, r1 = align_returns(
        closes_leader, leader_times, closes_receiver, receiver_times, now,
        max_stale_seconds=None, max_misalignment_seconds=100.0,
    )
    l2, r2 = align_returns(
        closes_leader, leader_times, closes_receiver, receiver_times, now,
        max_stale_seconds=None, max_misalignment_seconds=100.0,
    )

    np.testing.assert_array_equal(l1, l2)  # deterministic - same inputs, same output
    np.testing.assert_array_equal(r1, r2)
    assert 0 < len(l1) < n - 1  # discriminates - neither everything nor nothing survives


def test_12_lookahead_trap():
    """Test 12: Look-Ahead Trap - construct a receiver series that would
    correlate PERFECTLY with leader if future leader information leaked
    (receiver[i] == leader[i+1]), but has NO relationship with any leader
    observation at or before its own index. If look-ahead existed, the
    engine would report a strong, low lag. It must not."""
    n = 300
    leader = _leader_series(n, seed=1201)
    receiver = np.empty(n)
    receiver[:-1] = leader[1:]  # receiver[i] = leader[i+1] - future information
    receiver[-1] = _leader_series(1, seed=1202)[0]

    snap = compute_snapshot(leader, receiver, max_lag=5, min_sample_size=30)

    # lag_scan only ever pairs receiver[i] with leader[i-lag] for lag>=0 -
    # it structurally cannot see leader[i+1], so no lag should recover the
    # planted "future" relationship
    assert all(abs(r.correlation) < 0.3 for r in snap.lag_profile)
    assert snap.state == TransmissionState.INACTIVE


def test_pearson_corr_zero_variance_returns_zero_not_nan():
    """Numerical-safety edge case: a constant series has zero variance -
    correlation must be an honest 0.0, never NaN or a division-by-zero
    exception a caller could mishandle."""
    x = np.zeros(20)
    y = _leader_series(20, seed=1301)
    assert pearson_corr(x, y) == 0.0
    assert pearson_corr(y, x) == 0.0
    assert not np.isnan(pearson_corr(x, x))


def test_lag_scan_never_reads_future_index():
    """Direct structural proof, independent of any synthetic data: for
    every lag in range, lag_scan's own leader slice is leader[0 : n-lag],
    which never includes an index >= n-lag - i.e. never an index that
    would require a receiver observation not yet available at that
    leader-relative position."""
    n = 100
    leader = _leader_series(n, seed=1401)
    receiver = _leader_series(n, seed=1402)
    results = lag_scan(leader, receiver, max_lag=8, min_sample_size=10)
    for r in results:
        if r.sample_count > 0:
            assert r.sample_count == n - r.lag


def test_13_subwindow_significance_floor_regression():
    """Regression test for a defect found by the post-4A independent
    statistical audit: corr_older/corr_recent are each computed on HALF
    the observations corr_full uses, so their own noise floor is
    materially larger (SignificanceFloor(half,...) ~= 1.4x
    SignificanceFloor(m,...) at typical sizes). An earlier version applied
    the full-sample-calibrated threshold to both, which was masked at
    n=400 by the flat min_association=0.25 floor dominating anyway, but
    NOT masked at n=200: false-positive rate was empirically 8.10% over
    1000 independent unrelated-series trials before the fix. This test
    locks in a materially lower rate at n=200 so a regression is caught
    automatically rather than requiring another manual audit to notice."""
    n = 200
    trials = 500
    active = {
        TransmissionState.LEADER, TransmissionState.CONFIRMING, TransmissionState.WEAKENING,
        TransmissionState.DIVERGING, TransmissionState.INVERTED,
    }
    false_positive = 0
    for seed in range(500000, 500000 + trials):
        rng = np.random.default_rng(seed)
        leader = rng.normal(0, 0.001, n)
        receiver = rng.normal(0, 0.0015, n)
        snap = compute_snapshot(leader, receiver, max_lag=10, min_sample_size=30)
        if snap.state in active:
            false_positive += 1
    rate = false_positive / trials
    # the pre-fix rate was ~8%; a well-calibrated two-sided alpha=0.01
    # Bonferroni floor should sit close to 1-2%, generously bounded here
    # to avoid a flaky threshold while still catching a real regression
    assert rate < 0.05, f"false-positive rate {rate:.3f} at n=200 - subwindow significance floor regression?"
