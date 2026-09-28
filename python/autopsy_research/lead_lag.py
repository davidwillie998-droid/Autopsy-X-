"""Information Transmission / Lead-Lag measurement layer.

ENGINEERING DESIGN, not paper-sourced. This module is the executable
reference implementation for MQL5/Include/AutopsyX/InformationTransmission
Engine.mqh - same relationship as trade_direction.py has to
TickDirectionEngine.mqh: the algorithm is specified and tested here in
Python (where it can actually be run and asserted against), and the MQL5
file ports the identical logic for live use, documented in its own header
as mirroring this module.

TERMINOLOGY DISCIPLINE (deliberate, not an oversight): this module never
uses the word "causal" or "causality" anywhere in its public API. Lagged
correlation is INFORMATION TRANSMISSION / PREDICTIVE ASSOCIATION, not
causal proof - Granger-style lag-scanning shows temporal precedence and
statistical association, not a validated causal mechanism. If a future
phase implements an explicitly causal methodology (e.g. instrumental
variables, a structural VAR with identified shocks), that would earn
causal language; a Pearson correlation at a lag does not.

WHAT THIS MEASURES: given two already-computed return series (a "leader"
and a "receiver", aligned index-for-index on a SHARED reference bar
sequence - see the alignment note below), scan a bounded set of lags and
report, at whichever lag shows the strongest association:
  - direction (positive/negative/none)
  - association strength (|Pearson r| at that lag)
  - response magnitude (mean receiver return in the historically-implied
    direction, following a leader observation)
  - stability (how consistent the relationship is between an OLDER and a
    RECENT sub-window of the same data - not just "is it strong now")
  - regime-dependence (correlation recomputed within each regime bucket a
    caller supplies, using this codebase's OWN authoritative regime
    taxonomy - see RegimeClassifierEngine.mqh; this module does not
    invent a second one)
  - a transmission-state classification (see TransmissionState) built
    entirely from the older-vs-recent comparison, not a separate ad hoc
    rule
  - a confidence score that is the GATED MINIMUM of independent evidence
    factors (sample size, strength, stability), never a blind average,
    zeroed outright on INSUFFICIENT_DATA/INACTIVE, and penalized under
    DIVERGING/WEAKENING/INVERTED - matching this codebase's existing
    "hard gates, not blind averages" convention (TradePermissionMatrix.mqh)

ALIGNMENT CONVENTION (read this before touching any index math): both
return series are assumed to already be sampled at the SAME reference
bar-close sequence - i.e. index i in `leader_returns` and index i in
`receiver_returns` refer to the SAME wall-clock bar. Lag is therefore a
plain array-index offset into that shared sequence, not a raw
timestamp computation. This is a deliberate simplification, not a
general-purpose multi-timeframe/multi-session aligner: true differing-
session alignment (an instrument on a different trading calendar) is
NOT implemented here. The MQL5 port enforces this same convention by
construction - it only ever pushes a paired observation when BOTH
symbols' own closed bar at the same reference bar-close event was
readable; if either read fails, that whole pair is skipped, never
fabricated or approximated from one side alone.

LOOK-AHEAD DISCIPLINE: for lag >= 0, `receiver_returns[i]` is compared
against `leader_returns[i - lag]`, i.e. leader is read at or BEFORE the
receiver's own index, never after. lag == 0 compares same-index
(concurrent) closed bars - legitimate, not look-ahead, since both sides
are already-closed, already-known observations at the point of
computation. There is no code path in this module that reads
`leader_returns` at an index greater than `i`. See
test_lead_lag.py::test_lookahead_trap for an executable proof.
"""
from __future__ import annotations

from dataclasses import dataclass, field
from enum import Enum

import numpy as np
from scipy import stats


class TransmissionState(str, Enum):
    """Every state has an exact, computable definition (see
    compute_snapshot) - no state is added without one, per this phase's
    own instruction."""

    UNKNOWN = "UNKNOWN"
    INSUFFICIENT_DATA = "INSUFFICIENT_DATA"
    INACTIVE = "INACTIVE"
    LEADER = "LEADER"
    CONFIRMING = "CONFIRMING"
    WEAKENING = "WEAKENING"
    DIVERGING = "DIVERGING"
    INVERTED = "INVERTED"


@dataclass(frozen=True)
class LagResult:
    lag: int
    correlation: float
    sample_count: int


@dataclass(frozen=True)
class RegimeBucketResult:
    regime: int
    correlation: float
    sample_count: int
    sufficient: bool


@dataclass(frozen=True)
class TransmissionSnapshot:
    valid: bool
    state: TransmissionState
    direction: int  # +1, -1, or 0
    best_lag: int
    association_strength: float  # |r| at best_lag, 0..1
    response_magnitude: float
    stability: float  # 0..100
    sample_count: int
    confidence: float  # 0..100
    regime_buckets: tuple[RegimeBucketResult, ...] = field(default_factory=tuple)
    strongest_regime: int | None = None
    strongest_regime_correlation: float = 0.0
    reason: str = ""
    lag_profile: tuple[LagResult, ...] = field(default_factory=tuple)


def align_returns(
    leader_closes: np.ndarray,
    leader_times: np.ndarray,
    receiver_closes: np.ndarray,
    receiver_times: np.ndarray,
    now: float,
    max_stale_seconds: float | None = None,
    max_misalignment_seconds: float | None = None,
) -> tuple[np.ndarray, np.ndarray]:
    """Builds aligned leader/receiver LOG RETURN arrays from raw
    (time, close) series on each symbol's own reference bar-close
    sequence, mirroring InformationTransmissionEngine.mqh's own Sample()
    gating before any correlation math runs.

    Three DISTINCT checks, deliberately not conflated (an earlier draft
    conflated staleness with historical age itself, which made every
    non-trivial historical array fail its own staleness check purely by
    being older than `now` - caught by test_10_stale_data/
    test_11_timestamp_misalignment actually failing, fixed here):

      - MISSING/INVALID DATA (every pair): a non-positive close on either
        symbol drops that pair - never a fabricated/interpolated value.
      - FUTURE-BAR REJECTION (every pair): a timestamp > `now` drops that
        pair - a still-forming bar is never read as if it were closed
        (look-ahead protection).
      - MISALIGNMENT, if `max_misalignment_seconds` is given (every
        pair): drops a pair whose leader/receiver timestamps differ by
        more than the tolerance - the two symbols' own bar-close events
        drifted too far apart at that index to treat as the same
        reference bar.
      - STALENESS, if `max_stale_seconds` is given (ONLY the single most
        recent retained pair): historical pairs are not "stale" merely
        for being old relative to `now` - that is what makes them
        historical, not invalid. Staleness is a LIVE, current-tick
        concept (mirroring CDataIntegrityEngine's own convention of
        gating only the CURRENT tick, never retroactively invalidating
        already-closed history) - if the feed has gone quiet, only the
        newest pair is dropped; earlier history is unaffected.

    A dropped pair is removed entirely, never filled with a zero, a
    carried-forward value, or an interpolation - "no observation" and
    "zero movement" are different things and must never be conflated
    (this phase's own explicit instruction)."""
    n = min(len(leader_closes), len(receiver_closes), len(leader_times), len(receiver_times))
    leader_returns: list[float] = []
    receiver_returns: list[float] = []
    for i in range(1, n):
        lt, rt = leader_times[i], receiver_times[i]
        lc0, lc1 = leader_closes[i - 1], leader_closes[i]
        rc0, rc1 = receiver_closes[i - 1], receiver_closes[i]
        if lc0 <= 0 or lc1 <= 0 or rc0 <= 0 or rc1 <= 0:
            continue
        if lt > now or rt > now:
            continue
        if max_misalignment_seconds is not None and abs(lt - rt) > max_misalignment_seconds:
            continue
        leader_returns.append(float(np.log(lc1 / lc0)))
        receiver_returns.append(float(np.log(rc1 / rc0)))

    if leader_returns and max_stale_seconds is not None:
        newest_time = max(leader_times[n - 1], receiver_times[n - 1])
        if (now - newest_time) > max_stale_seconds:
            leader_returns = leader_returns[:-1]
            receiver_returns = receiver_returns[:-1]

    return np.array(leader_returns), np.array(receiver_returns)


def pearson_corr(x: np.ndarray, y: np.ndarray) -> float:
    """Sample Pearson correlation. Returns 0.0 (not NaN) on zero variance
    or fewer than 2 points - "no defined relationship" is honestly 0.0
    association strength, not a propagated NaN a caller could mistake
    for a real, weak-but-measured correlation of exactly zero."""
    if len(x) < 2 or len(y) < 2:
        return 0.0
    x = np.asarray(x, dtype=float)
    y = np.asarray(y, dtype=float)
    x_std = x.std()
    y_std = y.std()
    if x_std <= 0 or y_std <= 0:
        return 0.0
    return float(np.clip(np.corrcoef(x, y)[0, 1], -1.0, 1.0))


def lag_scan(
    leader_returns: np.ndarray,
    receiver_returns: np.ndarray,
    max_lag: int,
    min_sample_size: int,
) -> list[LagResult]:
    """Scans lag in [0, max_lag]. For each lag, pairs
    receiver_returns[i] with leader_returns[i - lag] for every valid i
    (i >= lag). Never reads leader_returns at an index > i (look-ahead
    discipline - see module docstring)."""
    if max_lag < 0:
        raise ValueError("max_lag must be >= 0")
    n = min(len(leader_returns), len(receiver_returns))
    results: list[LagResult] = []
    for lag in range(0, max_lag + 1):
        if n - lag < 2:
            results.append(LagResult(lag=lag, correlation=0.0, sample_count=max(0, n - lag)))
            continue
        leader_slice = leader_returns[0 : n - lag]
        receiver_slice = receiver_returns[lag:n]
        corr = pearson_corr(leader_slice, receiver_slice)
        results.append(LagResult(lag=lag, correlation=corr, sample_count=len(leader_slice)))
    return results


def _split_half(n: int) -> int:
    return n // 2


def _significance_floor(n: int, num_comparisons: int, alpha: float = 0.01) -> float:
    """Minimum |Pearson r| distinguishable from pure noise at a two-sided
    `alpha` significance level, Bonferroni-corrected for having scanned
    `num_comparisons` lags and taken the strongest ("best of N" selection
    inflates the apparent strength of a purely noisy candidate - an
    empirical check across 100 independent seeded pairs of genuinely
    unrelated series, n=400, max_lag=10, found a 22% false-positive rate
    at a flat |r|>=0.15 threshold and 0% at 0.25, which is why the
    default below changed; this function is the general, sample-size-
    and lag-count-aware version of that same correction, not a value
    tuned to any one test's own random seed - see test_3_no_relationship
    and test_12_lookahead_trap, whose failures against the OLD flat
    threshold is what surfaced this problem in the first place).
    Uses SE(r) ~= 1/sqrt(n-3) (the standard Fisher z-transform large-n
    approximation)."""
    if n < 4:
        return 1.0  # too few observations to say anything is significant
    alpha_adjusted = alpha / max(1, num_comparisons)
    z = float(stats.norm.ppf(1.0 - alpha_adjusted / 2.0))
    se = 1.0 / np.sqrt(n - 3)
    return float(np.clip(z * se, 0.0, 1.0))


def compute_snapshot(
    leader_returns: np.ndarray,
    receiver_returns: np.ndarray,
    max_lag: int = 10,
    min_sample_size: int = 30,
    min_association: float = 0.25,
    weakening_ratio: float = 0.5,
    regimes: np.ndarray | None = None,
    min_regime_sample_size: int = 15,
) -> TransmissionSnapshot:
    """Builds one TransmissionSnapshot from two aligned return series (see
    module docstring for the alignment convention). `regimes`, if given,
    must be the SAME length as receiver_returns and hold the regime
    classification prevailing at the receiver's own observation index
    (i.e. RegimeClassifierEngine's own ENUM_AX_REGIME_CLASS value at that
    bar) - this module reuses that taxonomy, never invents its own.

    `min_association` (default 0.25, raised from an initial 0.15 after an
    empirical false-positive check - see _significance_floor's own
    docstring) is a FLOOR, not the only gate: the EFFECTIVE threshold used
    below is max(min_association, _significance_floor(...)), so a caller
    configuring a smaller sample size or a wider lag scan than the default
    still gets a statistically-grounded minimum, not just this flat
    number applied blindly regardless of how much multiple-comparison
    exposure the scan actually had."""
    n = min(len(leader_returns), len(receiver_returns))
    if n < min_sample_size:
        return TransmissionSnapshot(
            valid=False,
            state=TransmissionState.INSUFFICIENT_DATA,
            direction=0,
            best_lag=-1,
            association_strength=0.0,
            response_magnitude=0.0,
            stability=0.0,
            sample_count=n,
            confidence=0.0,
            reason=f"sample_count {n} < min_sample_size {min_sample_size}",
        )

    lag_results = lag_scan(leader_returns, receiver_returns, max_lag, min_sample_size)
    eligible = [r for r in lag_results if r.sample_count >= min_sample_size]
    if not eligible:
        return TransmissionSnapshot(
            valid=False,
            state=TransmissionState.INSUFFICIENT_DATA,
            direction=0,
            best_lag=-1,
            association_strength=0.0,
            response_magnitude=0.0,
            stability=0.0,
            sample_count=n,
            confidence=0.0,
            reason="no lag reached min_sample_size",
            lag_profile=tuple(lag_results),
        )

    best = max(eligible, key=lambda r: abs(r.correlation))
    best_lag = best.lag
    corr_full = best.correlation

    leader_slice = leader_returns[0 : n - best_lag]
    receiver_slice = receiver_returns[best_lag:n]
    m = len(leader_slice)

    # older-vs-recent stability split, on the SAME (leader, receiver) pairs
    # used for the best-lag correlation, in original chronological order
    half = _split_half(m)
    if half >= 2:
        corr_older = pearson_corr(leader_slice[:half], receiver_slice[:half])
        corr_recent = pearson_corr(leader_slice[m - half :], receiver_slice[m - half :])
        stability = float(np.clip(100.0 - 100.0 * abs(corr_older - corr_recent) / 2.0, 0.0, 100.0))
    else:
        corr_older = corr_full
        corr_recent = corr_full
        stability = 0.0  # not enough data to say anything about stability - never fabricated

    # regime-dependence bucketing (reuses the caller's own regime tags,
    # never recomputed here)
    regime_buckets: list[RegimeBucketResult] = []
    strongest_regime = None
    strongest_regime_corr = 0.0
    regime_slice = None
    if regimes is not None:
        regime_slice = np.asarray(regimes[best_lag:n])
        for regime_value in sorted(set(int(r) for r in regime_slice)):
            mask = regime_slice == regime_value
            count = int(mask.sum())
            sufficient = count >= min_regime_sample_size
            corr = pearson_corr(leader_slice[mask], receiver_slice[mask]) if sufficient else 0.0
            regime_buckets.append(
                RegimeBucketResult(regime=regime_value, correlation=corr, sample_count=count, sufficient=sufficient)
            )
            if sufficient and abs(corr) > abs(strongest_regime_corr):
                strongest_regime = regime_value
                strongest_regime_corr = corr

    # transmission-state waterfall - every branch has an exact, stated
    # numeric definition (module docstring / phase instruction). IMPORTANT
    # ORDERING: the older-vs-recent checks (INVERTED/DIVERGING/WEAKENING)
    # are evaluated BEFORE the corr_full-based INACTIVE gate, not after -
    # a textbook inversion (strong positive half, strong negative half of
    # similar magnitude) nets corr_full toward zero BY CONSTRUCTION, so
    # gating on corr_full first would misclassify the exact scenario
    # INVERTED exists to catch as INACTIVE instead (fixed after this was
    # caught by test_8_relationship_inversion actually failing).
    #
    # Every comparison below uses `effective_min_association`, the
    # multiple-comparisons-corrected floor (see _significance_floor), not
    # the raw `min_association` parameter directly - scanning max_lag+1
    # lags and keeping the strongest is a "best of N" selection, and an
    # empirical check found it inflates a purely noisy pair's apparent
    # strength well past a flat 0.15 threshold on a real fraction of
    # random draws (test_3_no_relationship/test_12_lookahead_trap both
    # failed against the flat threshold before this was added).
    effective_min_association = max(min_association, _significance_floor(m, len(lag_results)))
    min_half_sample = max(5, min_sample_size // 4)
    half_has_enough = half >= min_half_sample
    if not half_has_enough:
        # too little data to compare older-vs-recent - fall back to a
        # whole-window read only, never fabricate a stability-derived state
        state = TransmissionState.INACTIVE if abs(corr_full) < effective_min_association else TransmissionState.LEADER
    elif (
        abs(corr_older) >= effective_min_association
        and abs(corr_recent) >= effective_min_association
        and np.sign(corr_older) != np.sign(corr_recent)
    ):
        state = TransmissionState.INVERTED
    elif abs(corr_older) >= effective_min_association and abs(corr_recent) < effective_min_association:
        state = TransmissionState.DIVERGING
    elif abs(corr_older) >= effective_min_association and abs(corr_recent) < abs(corr_older) * weakening_ratio:
        state = TransmissionState.WEAKENING
    elif abs(corr_full) < effective_min_association:
        # neither the full window nor either half shows a meaningful
        # relationship - genuinely nothing here, not a masked inversion
        state = TransmissionState.INACTIVE
    elif strongest_regime is not None and regime_slice is not None and int(regime_slice[-1]) == strongest_regime:
        # "confirming" requires more than just persistence - the CURRENT
        # regime must match the regime bucket where this relationship is
        # historically strongest
        state = TransmissionState.CONFIRMING
    else:
        state = TransmissionState.LEADER

    # direction/strength describe whichever correlation is actually
    # relevant to the reported state: the live-relevant recent reading for
    # INVERTED, the fading historical reading for DIVERGING/WEAKENING (it
    # no longer holds now, but "what it used to be" is the honest content
    # of those two states), and the stable full-window reading otherwise.
    if state == TransmissionState.INVERTED:
        direction = 1 if corr_recent > 0 else -1
        association_strength = abs(corr_recent)
    elif state in (TransmissionState.DIVERGING, TransmissionState.WEAKENING):
        direction = 1 if corr_older > 0 else -1
        association_strength = abs(corr_older)
    elif state in (TransmissionState.INACTIVE,):
        direction = 0
        association_strength = abs(corr_full)
    else:
        direction = 1 if corr_full > 0 else -1
        association_strength = abs(corr_full)

    # response magnitude: mean receiver return in the historically-implied
    # direction, following each leader observation (0.0, not fabricated,
    # when direction is inactive)
    response_magnitude = float(np.mean(receiver_slice) * direction) if direction != 0 else 0.0

    # confidence: gated minimum of independent evidence factors, never a
    # blind weighted average (this phase's own instruction + this
    # codebase's existing TradePermissionMatrix.mqh convention)
    if state in (TransmissionState.INSUFFICIENT_DATA, TransmissionState.INACTIVE, TransmissionState.UNKNOWN):
        confidence = 0.0
    else:
        target_sample = min_sample_size * 3
        sample_factor = float(np.clip(100.0 * (m - min_sample_size) / max(1, target_sample - min_sample_size), 0.0, 100.0))
        strength_factor = float(np.clip(100.0 * association_strength, 0.0, 100.0))
        stability_factor = stability if half_has_enough else 50.0  # neutral, not zero, not fabricated-high
        confidence = min(sample_factor, strength_factor, stability_factor)
        if state in (TransmissionState.DIVERGING, TransmissionState.WEAKENING, TransmissionState.INVERTED):
            confidence *= 0.5

    return TransmissionSnapshot(
        valid=True,
        state=state,
        direction=direction,
        best_lag=best_lag,
        association_strength=association_strength,
        response_magnitude=response_magnitude,
        stability=stability,
        sample_count=m,
        confidence=confidence,
        regime_buckets=tuple(regime_buckets),
        strongest_regime=strongest_regime,
        strongest_regime_correlation=strongest_regime_corr,
        reason="",
        lag_profile=tuple(lag_results),
    )
