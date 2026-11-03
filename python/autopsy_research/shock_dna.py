"""Shock DNA / Shock Characterization Engine - Phase 4B reference implementation.

ENGINEERING DESIGN, not paper-sourced. This module is the executable
reference implementation for MQL5/Include/AutopsyX/ShockDNAEngine.mqh - same
relationship as lead_lag.py has to InformationTransmissionEngine.mqh: the
algorithm is specified and tested here in Python (where it can actually be
run and asserted against), and the MQL5 file ports the identical logic for
live use, documented in its own header as mirroring this module.

WHAT THIS IS: a per-bar, stateful characterization of how a single market
shock EVENT behaves over its own short lifecycle - what kind of shock it
was, how the market absorbed it, and what happened afterward. It is a
market-event DESCRIPTION engine, not a detector of "large candles" and not
a predictive or trading signal (see CLAIM-HONESTY below).

============================================================================
1. WHAT ALREADY EXISTS AND IS REUSED, NOT DUPLICATED
============================================================================
Per this phase's own explicit instruction, the following existing,
authoritative infrastructure is consumed as an ALREADY-COMPUTED input to
this engine and never recomputed or reclassified here:

  - ATR and the existing 5-state volatility taxonomy (AX_VOL_NORMAL/LOW/
    HIGH/EXTREME/SHOCK) - CVolatilityEngine (VolatilityEngine.mqh). This
    engine's own onset detection is a DIFFERENT, complementary question
    from CVolatilityEngine's SHOCK state: CVolatilityEngine asks "has ATR
    itself accelerated sharply over the last few bars" (a volatility-of-
    volatility question). This engine asks "did THIS bar's own net price
    displacement, measured against the currently-prevailing ATR, exceed
    what recent bars have typically produced" (a single-bar-displacement
    question). The two can and do disagree: a market can have a genuinely
    shocking single bar while ATR itself is still catching up (ATR is a
    lagging, smoothed measure), or ATR can be accelerating from a series of
    only moderately-sized bars with no single standout bar. Because they
    are different statistical objects, CVolatilityEngine's own SHOCK state
    is reused here only as a CORROBORATING signal (surfaced on the
    snapshot, referenced in the confidence calculation), never as the
    primary shock trigger and never recomputed.

  - The 9-state direction-aware regime taxonomy (ENUM_AX_REGIME_CLASS) -
    CRegimeClassifierEngine (RegimeClassifierEngine.mqh, Phase 3). This
    engine reads the caller's already-computed SAxRegimeClassification for
    the same bar and records regime + regimeConfidence as descriptive
    context. No new regime classifier is built here.

  - Cross-asset / information-transmission context -
    CInformationTransmissionEngine (InformationTransmissionEngine.mqh,
    Phase 4A). This engine reads the caller's already-computed
    TransmissionSnapshot (if the caller has one configured) purely as a
    descriptive cross-asset-confirmation input. InformationTransmissionEngine.
    mqh itself is NOT modified by this phase.

  - Data-quality / feed-integrity gating - CDataIntegrityEngine
    (DataIntegrity.mqh). This engine takes the caller's already-computed
    dataIntegrityOk/dataIntegrityReason for the current tick as a
    parameter, exactly like every other Phase 3/4A engine's own Sample()
    signature. It does not re-derive spread/staleness/duplicate-tick
    checks. Where this engine needs its OWN readiness signal (enough
    bar-level history to trust its own ATR-relative ratios), it tracks a
    small internal bars-sampled counter, mirroring
    VolatilitySerialityEngine.mqh's own m_returnCount/sampleSize pattern -
    CVolatilityEngine and CRegimeEngine do not expose a public "ATR history
    ready" flag, so this is a genuinely new but minimal and narrowly-scoped
    piece of state, not a duplicate data-integrity system.

WHAT IS GENUINELY NEW in this file (the only new computation): (a) the
ATR-relative single-bar displacement ratio used to detect shock ONSET, (b)
the event-lifecycle tracker (bars-since-onset, cumulative displacement,
running maximum excursion / maximum adverse excursion, retracement
fraction) used to classify a tracked event's state, and (c) the state
waterfall built from those two things. Velocity/acceleration here are
BAR-LEVEL, ATR-normalized quantities (this bar's own incremental
contribution to the tracked event's cumulative displacement, and its
bar-over-bar change) - a deliberately different statistical object from
CMomentumEngine's own Velocity()/Acceleration(), which are TICK-ARRIVAL-RATE
measures (ticks per second, and its change) computed over a rolling window
of raw ticks that can straddle a still-forming bar. Reusing
CMomentumEngine's tick-level fields here would have meant dressing up a
tick-level, intrabar-eligible measurement as a bar-closed-only one - the
exact same distinction VolatilitySerialityEngine.mqh already drew, for the
same underlying reason, against CMomentumEngine.PersistenceRatio(). This
file computes its own honestly-labeled, bar-level, closed-bar-only
equivalent instead, and owns its own bar-level OHLC read (CopyClose/
CopyHigh/CopyLow with shift>=1), matching this codebase's "each engine owns
its own read" convention.

============================================================================
2. THE SHOCK DEFINITION (mathematical, not "a large candle")
============================================================================
Primary definition - ONSET MAGNITUDE:

    onset_magnitude_atr(t) = | close(t) - close(t-1) | / atr_price(t)

i.e. the closed bar's own net (close-to-close) displacement, expressed as a
multiple of the currently-prevailing ATR (in the same price units, so the
ratio is dimensionless). A shock ONSET is flagged at bar t when no event is
currently being tracked and onset_magnitude_atr(t) >= onset_threshold_atr
(default 1.5, configurable).

Why close-to-close displacement, not high-low range: a bar can have a huge
intrabar range yet close back near where it opened - that is evidence of
absorption or a failed push, not of a shock that actually repriced the
market. Net displacement is what the market actually settled on, closed
the session/bar with, and what the NEXT bar's own returns are computed
against. Range is therefore tracked as a distinct SECONDARY descriptor
(range_expansion_atr, below), not folded into the primary trigger - keeping
"how big was the settled move" and "how much intrabar noise/exploration
occurred" as separate, individually-testable dimensions, per this phase's
own instruction not to force multiple concepts into one number.

Why ATR-relative, not a fixed-point threshold: a fixed-point (or fixed-
pip) threshold is not scale-aware - it would flag differently on
instruments quoted at different price levels, and would flag differently
for the SAME instrument depending on how volatile the recent market has
been (see NORMALIZATION below, and the dedicated cross-scale tests in
test_shock_dna.py: test_23/test_24). Dividing by the currently-prevailing
ATR (itself in the same price units as the raw displacement) cancels the
price-scale term and produces a dimensionless ratio that is directly
comparable across instruments and across volatility regimes of the same
instrument. This mirrors the same normalization principle this codebase
already applies elsewhere (e.g. RegimeClassifierEngine.mqh's volRatio,
CapacityCrowdingEngine.mqh's distanceAtr) - though, importantly, none of
those measure the SAME thing as onset_magnitude_atr (they measure ATR
itself relative to its own average, or a distance relative to ATR - not a
single bar's own net displacement relative to ATR), so no existing
threshold VALUE from elsewhere in the codebase is borrowed here. Borrowing
a numeral from a different statistical object merely because it "looks
similar" would misrepresent reuse - the value below is instead a
documented, configurable engineering choice, justified only by the
normalization argument above, not by an empirically-fitted tail
percentile.

HONEST LIMITATION on the threshold's own calibration: this sandboxed build
environment has no live historical price feed to compute an empirical
percentile for onset_threshold_atr (e.g. "the top 1% of historical bars").
The default of 1.5x prevailing ATR is therefore a stated, documented,
configurable engineering choice - not a data-derived, backtested
threshold - exactly as VolatilitySerialityEngine.mqh's own
m_expansionAccelPct=20.0 was documented as "THIS file's own configurable
threshold... deliberately lower than a typical shock threshold", not an
empirically-optimal one. A caller who has real historical data available is
expected to calibrate onset_threshold_atr via Configure() for their own
instrument/timeframe; this module does not claim the default is optimal
for any specific market.

SECONDARY DESCRIPTORS (computed every bar the engine is Sample()'d,
independent of whether an event is currently tracked):

  - magnitude_raw_pts: | close(t) - close(t-1) | in points (raw, for
    reference/debugging only - never compared against any threshold itself,
    since raw points are not scale-aware).
  - range_expansion_atr: (high(t) - low(t)) / atr_price(t) - how much
    intrabar range this bar produced relative to typical recent range,
    independent of where the bar actually closed.
  - direction: sign of the tracked event's own onset displacement (+1/-1),
    or 0 when no event is active. Direction is fixed at onset and never
    recomputed mid-event (see LOOK-AHEAD PROTECTION).

DIMENSIONS EXPLICITLY NOT MEASURED (left missing, not fabricated): volume /
tick-volume anomaly is not a dimension of this module. No existing,
independently-validated tick/real-volume reliability layer exists elsewhere
in this codebase to build on (a genuinely new one would itself duplicate a
data-quality concern that belongs to DataIntegrity.mqh, per this phase's
own instruction not to solve that problem here) - the field is therefore
simply absent from the schema rather than populated with an unreliable
proxy.

============================================================================
3. SHOCK DNA DIMENSIONS -> SNAPSHOT FIELDS
============================================================================
See ShockDNASnapshot below for the full field list and each field's exact
definition. Every dimension named in this phase's own spec is either a
named field, a documented "not measured" omission (volume/tick-volume,
above), or explicitly folded into an existing field with a stated reason
(e.g. "Direction" and "Magnitude" are captured jointly via the signed
event_displacement_atr plus the separate `direction` field; "Velocity" and
"Acceleration" are velocity_atr/acceleration_atr).

============================================================================
4. STATE TAXONOMY (9 states, mutually exclusive) - see ShockState
============================================================================
UNKNOWN            - data quality bad or ATR unusable this bar; no
                      classification attempted.
INSUFFICIENT_DATA  - data usable, but this engine has not yet accumulated
                      enough bar-level history to trust its own ATR-
                      relative ratios.
NONE                - sufficient data/history; no event currently tracked;
                      this bar's own onset_magnitude_atr did not reach
                      onset_threshold_atr.
ONSET               - a new event was just detected THIS bar (k == 0).
IMPULSE             - event still extending in its onset direction and
                      still at/near its own running peak excursion
                      (k in [1, impulse_bars]).
FOLLOW_THROUGH      - event has moved past its impulse window and remains
                      meaningfully extended beyond its onset magnitude,
                      without large retracement.
ABSORPTION          - event has given back a meaningful (but not
                      reversal-grade) fraction of its peak excursion, OR
                      has stalled without extending, reversing, or decaying
                      (the waterfall's own default/catch-all case - see
                      below).
REVERSAL            - event's cumulative displacement has flipped past zero
                      to a meaningful magnitude in the OPPOSITE direction
                      from onset, or has given back most (>= 75%, default)
                      of its peak excursion.
NORMALIZING         - event's own tracked lifecycle window has elapsed
                      (hard cap), or its cumulative displacement has
                      decayed back near zero before that cap - terminal
                      state; the event stops being tracked after this bar.

============================================================================
5. STATE WATERFALL (deterministic, first match wins) - see _classify()
============================================================================
Given an active tracked event at bars-since-onset k, with:
  onset_sign          = sign(onset_displacement_atr)          (+1 or -1)
  cum                  = cumulative_displacement_atr(k)         (signed)
  max_exc              = max over j in [0,k] of max(0, onset_sign*cum(j))
  adverse_exc          = max_exc - onset_sign*cum               (>= 0)
  retracement          = adverse_exc / max_exc  if max_exc > EPS else 0.0

  1. k >= lifecycle_bars                                   -> NORMALIZING
  2. |cum| <= normalization_floor_atr and k >= min_decay_bars -> NORMALIZING
  3. onset_sign*cum <= -reversal_min_magnitude_atr           -> REVERSAL
  4. retracement >= reversal_retracement_frac                -> REVERSAL
  5. retracement >= absorption_retracement_frac               -> ABSORPTION
  6. k == 0                                                    -> ONSET
  7. k <= impulse_bars and onset_sign*cum >= max_exc - EPS     -> IMPULSE
  8. onset_sign*cum >= |onset_displacement_atr|*follow_through_mult
                                                                -> FOLLOW_THROUGH
  9. else (default/catch-all: shock happened, not retracing
     heavily, not extending, not yet decayed)                  -> ABSORPTION

Every threshold above is independently configurable; boundary conditions at
each inequality are directly unit-tested (test_shock_dna.py) rather than
merely exercised incidentally.

SINGLE-EVENT TRACKING (no overlapping-event stack): this engine tracks at
most ONE active event at a time. While an event is active, every
subsequent bar's own signed return is folded into THAT event's cumulative
displacement (whether it extends the event further in its onset direction,
or moves against it - see REVERSAL above) - a new bar exceeding
onset_threshold_atr on its own does NOT spawn a second, independently-
tracked event while one is already active. Only once the active event
reaches NORMALIZING (the only state that clears it) can a fresh onset be
detected on a later bar. This is a deliberate simplification, directly
exercised by test_shock_dna.py's "two shocks close together" and "opposite
shock after initial shock" tests: a second large move while an event is
still active is characterized as that event's own continuation or reversal,
not as a second event.

============================================================================
6. LIFECYCLE / LIVE-VS-COMPLETED SEPARATION (mandatory architectural rule)
============================================================================
This engine is fed ONE CLOSED BAR AT A TIME, in chronological order, via
repeated calls to ShockDNAEngine.update(). Each call:
  (a) reads only the bar just passed in (already closed - the caller is
      responsible for never passing a still-forming bar, exactly like every
      other engine's own shift>=1 discipline elsewhere in this codebase),
  (b) updates internal state (the active event, if any) using ONLY that
      bar's own OHLC/ATR/context, never anything from a later bar, and
  (c) returns a snapshot describing the CURRENT, live state of the event as
      of that bar - never a "final outcome" computed with hindsight.

There is therefore no separate "completed shock" data structure with
privileged access to future bars: a "completed" event is simply one whose
live snapshot, on some later bar, reported NORMALIZING. Once NORMALIZING is
reported, the engine stops tracking that event (returns to NONE-eligible)
and a query for that event's outcome after the fact is answered ONLY by
having recorded the live snapshots as they were produced bar-by-bar - never
by recomputing the event's history with access to bars beyond the query
point. test_shock_dna.py's test_15 is the dedicated leakage regression:
replaying the same bar sequence with extra future bars appended must never
change any snapshot already produced for an earlier bar - the classic
prefix-invariance check: two runs that agree on their shared prefix
regardless of what comes after it. test_16 (incomplete current bar) and
test_17 (shock during regime transition) are separate, narrower tests -
malformed-OHLC rejection and regime-field passthrough respectively - not
themselves leakage tests.

============================================================================
7. LOOK-AHEAD PROTECTION
============================================================================
At bar t, update() sees only: this bar's own OHLC, this bar's own
already-computed atr_price, this bar's own already-computed regime/
transmission context (both of which are themselves computed by their OWN
engines using only information up to and including bar t, per their own
existing look-ahead discipline), and the event-tracking state accumulated
from bars strictly before t. No field of ShockDNASnapshot is ever computed,
even partially, from a bar not yet passed to update(). This is verified
directly (not merely assumed) by test_shock_dna.py's prefix-invariance
regression test.

============================================================================
8. CONFIDENCE METHODOLOGY
============================================================================
confidence = 100 * min(sample_factor, quality_factor, magnitude_factor,
                         consistency_factor, cross_asset_factor,
                         regime_certainty_factor)

A GATED MINIMUM of independent evidence-quality factors, never a blind
average - the same convention already established in
TradePermissionMatrix.mqh and reused in InformationTransmissionEngine.mqh/
RegimeClassifierEngine.mqh. This is not a probability and is never called
one - it represents EVIDENCE QUALITY (how much this bar's classification
should be trusted), not "probability the shock is real" or "probability of
a profitable outcome". A single very large bar (high magnitude_factor)
cannot alone drive confidence to an extreme value, because it is GATED
against sample_factor (bars of history accumulated), quality_factor (data
integrity), consistency_factor (OHLC/ATR sanity), cross_asset_factor
(whether corroborating cross-asset data even exists this bar), and
regime_certainty_factor (the classifier's own confidence in the current
regime label) - if any one of those is low, confidence stays low
regardless of how large the triggering move was. See
test_shock_dna.py::test_confidence_not_driven_by_magnitude_alone.

============================================================================
9. OUTLIER DEFENSE
============================================================================
Per this phase's own instruction, this module does NOT add an ad-hoc
outlier filter (e.g. winsorization/clipping) to work around Phase 4A's own
documented Pearson-correlation outlier-sensitivity finding
(docs/PHASE4A_AUDIT_REPORT.md) - that finding concerns a DIFFERENT
computation (lag-correlation) that this module does not perform. This
module's own job description is in fact the opposite of filtering out
large moves: a genuinely large, real single-bar move IS the primary subject
this engine exists to characterize, so it deliberately does NOT distinguish
"legitimate large move" from "bad tick" - that distinction belongs to
CDataIntegrityEngine (upstream, already gating dataIntegrityOk before this
module ever sees the bar) and to whatever produced the OHLC series in the
first place. Raw observations are never modified, clipped, or replaced with
a fabricated value anywhere in this module: a bar's OHLC is used exactly as
supplied, or the bar is excluded from event-tracking on data-quality
grounds via UNKNOWN/INSUFFICIENT_DATA - there is no third option that
silently alters an observation. Multiple back-to-back large bars are
handled by the state waterfall itself (test_10/test_11/test_21/test_22
exercise exactly this), not by a separate outlier layer.

============================================================================
10. CLAIM-HONESTY (mandatory, per this phase's own instruction)
============================================================================
Nothing in this module claims, implies, or should be read as claiming that
a detected shock predicts subsequent price movement, causes any subsequent
move, generates alpha, is profitable, improves trading performance, or that
a high confidence value means a high probability of profit. This is a
market-event characterization engine only. No forward-return statistics,
no backtest, and no profitability claim of any kind appears anywhere in
this module or its tests.

============================================================================
11. COMPUTATIONAL BOUNDS
============================================================================
update() does O(1) work per call (no scans of historical arrays beyond the
active event's own already-tracked running max/adverse-max, which are
maintained incrementally, not recomputed from scratch each bar). No
unbounded array, no full-history rescan, no nested loop over history, no
external API call, no ML. Internal state is a single optional
"active event" record plus a small bars-sampled counter - fixed, finite
memory regardless of how long the engine runs.

============================================================================
12. OBSERVATIONAL ONLY / NOT WIRED
============================================================================
This module is not imported by, and has no effect on, any entry, signal,
permission, risk, sizing, execution, management, or journal logic anywhere
in this codebase. It exists to be called by future research/observational
code only.
"""

from __future__ import annotations

from dataclasses import dataclass
from enum import Enum
from typing import Optional


EPS = 1e-9


class ShockState(str, Enum):
    UNKNOWN = "UNKNOWN"
    INSUFFICIENT_DATA = "INSUFFICIENT_DATA"
    NONE = "NONE"
    ONSET = "ONSET"
    IMPULSE = "IMPULSE"
    FOLLOW_THROUGH = "FOLLOW_THROUGH"
    ABSORPTION = "ABSORPTION"
    REVERSAL = "REVERSAL"
    NORMALIZING = "NORMALIZING"


@dataclass
class ShockDNAConfig:
    onset_threshold_atr: float = 1.5
    impulse_bars: int = 2
    follow_through_mult: float = 0.6
    absorption_retracement_frac: float = 0.5
    reversal_retracement_frac: float = 0.75
    reversal_min_magnitude_atr: float = 0.5
    normalization_floor_atr: float = 0.3
    min_decay_bars: int = 2
    lifecycle_bars: int = 10
    min_history_bars: int = 20  # own bars-sampled readiness floor (see file header, section 1)

    def __post_init__(self) -> None:
        self.onset_threshold_atr = max(0.01, self.onset_threshold_atr)
        self.impulse_bars = max(0, int(self.impulse_bars))
        self.follow_through_mult = max(0.0, self.follow_through_mult)
        self.absorption_retracement_frac = min(1.0, max(0.0, self.absorption_retracement_frac))
        self.reversal_retracement_frac = min(1.0, max(0.0, self.reversal_retracement_frac))
        self.reversal_min_magnitude_atr = max(0.0, self.reversal_min_magnitude_atr)
        self.normalization_floor_atr = max(0.0, self.normalization_floor_atr)
        self.min_decay_bars = max(0, int(self.min_decay_bars))
        self.lifecycle_bars = max(1, int(self.lifecycle_bars))
        self.min_history_bars = max(1, int(self.min_history_bars))


@dataclass
class ShockDNASnapshot:
    timestamp: Optional[int]
    valid: bool
    data_quality_ok: bool
    data_quality_reason: str

    shock_detected: bool
    shock_state: ShockState
    direction: int  # -1, 0, +1

    magnitude_raw_pts: float
    normalized_magnitude: float  # this bar's own |return|/ATR ratio (always computed when valid)
    event_magnitude_atr: float   # |cumulative displacement| of the ACTIVE event, 0 if none
    range_expansion_atr: float

    velocity_atr: float
    acceleration_atr: float
    persistence_bars: int
    max_excursion_atr: float
    max_adverse_excursion_atr: float
    retracement_fraction: float

    follow_through: bool
    absorption: bool
    recovery: bool

    volatility_engine_shock: bool  # CVolatilityEngine.State()==AX_VOL_SHOCK passthrough, corroborating only

    regime: Optional[str]
    regime_strength: float
    information_transmission_state: Optional[str]
    transmission_available: bool
    cross_asset_confirmation: Optional[bool]

    confidence: float


@dataclass
class _ActiveEvent:
    onset_displacement_atr: float
    onset_sign: int
    k: int = 0
    cumulative_displacement_atr: float = 0.0
    max_excursion_atr: float = 0.0
    prev_velocity_atr: float = 0.0


class ShockDNAEngine:
    """Stateful, bar-by-bar shock characterization engine. See module docstring."""

    def __init__(self, config: Optional[ShockDNAConfig] = None) -> None:
        self.config = config or ShockDNAConfig()
        self._active: Optional[_ActiveEvent] = None
        self._bars_sampled = 0

    def reset(self) -> None:
        self._active = None
        self._bars_sampled = 0

    def update(
        self,
        *,
        timestamp: Optional[int],
        close_prev: float,
        close_curr: float,
        high_curr: float,
        low_curr: float,
        atr_price: float,
        point: float,
        data_quality_ok: bool,
        data_quality_reason: str = "",
        vol_state_is_shock: bool = False,
        regime: Optional[str] = None,
        regime_strength: float = 0.0,
        # code-review finding: this default was True, inconsistent with both regime_strength's own
        # 0.0 default and the sibling transmission_available's False default - a caller who omits
        # regime info entirely (a plausible real caller per this module's own OBSERVATIONAL-ONLY
        # design, e.g. ad-hoc research code with no regime engine wired up) got regime_available=True
        # + regime_strength=0.0, which the gated-minimum confidence formula reads as "regime IS
        # available and reports zero certainty" - silently forcing confidence to 0.0 on every single
        # bar, defeating the field's purpose. False (matching transmission_available's own default)
        # is the correct "no regime data supplied" default; callers WITH real regime data must now
        # pass regime_available=True explicitly, exactly as they already must for transmission_available.
        regime_available: bool = False,
        transmission_state: Optional[str] = None,
        transmission_direction: int = 0,
        transmission_available: bool = False,
    ) -> ShockDNASnapshot:
        cfg = self.config

        # --- UNKNOWN: caller-reported data quality bad, or ATR/prices unusable this bar ---
        atr_usable = atr_price is not None and atr_price > 0
        prices_sane = (
            close_prev is not None and close_curr is not None
            and high_curr is not None and low_curr is not None
            and close_prev > 0 and close_curr > 0
            and high_curr >= low_curr and high_curr > 0 and low_curr > 0
        )
        if not data_quality_ok or not atr_usable or not prices_sane:
            reason = data_quality_reason if not data_quality_ok else (
                "ATR unusable (<= 0)" if not atr_usable else "Non-sane OHLC (high < low or non-positive price)"
            )
            # a genuinely bad/unusable bar does not advance the active event's own bar counter -
            # it is excluded from the event's history entirely (outlier-defense section 9: never
            # silently fold a flagged-bad observation into the tracked lifecycle).
            return self._snapshot_unavailable(timestamp, ShockState.UNKNOWN, False, reason, regime, regime_strength,
                                               transmission_state, transmission_available, vol_state_is_shock)

        # data usable this bar - count it toward this engine's own readiness floor
        self._bars_sampled += 1

        if self._bars_sampled < cfg.min_history_bars:
            reason = f"Insufficient bar history: {self._bars_sampled} bars (need {cfg.min_history_bars})"
            return self._snapshot_unavailable(timestamp, ShockState.INSUFFICIENT_DATA, True, reason, regime,
                                               regime_strength, transmission_state, transmission_available,
                                               vol_state_is_shock)

        point_safe = point if point and point > 0 else 0.00001
        magnitude_raw_pts = abs(close_curr - close_prev) / point_safe
        normalized_magnitude = abs(close_curr - close_prev) / atr_price
        range_expansion_atr = (high_curr - low_curr) / atr_price
        signed_return_atr = (close_curr - close_prev) / atr_price

        if self._active is None:
            if normalized_magnitude >= cfg.onset_threshold_atr:
                onset_sign = 1 if signed_return_atr > 0 else -1
                self._active = _ActiveEvent(
                    onset_displacement_atr=signed_return_atr,
                    onset_sign=onset_sign,
                    k=0,
                    cumulative_displacement_atr=signed_return_atr,
                    max_excursion_atr=max(0.0, onset_sign * signed_return_atr),
                    prev_velocity_atr=0.0,
                )
                # code-review finding: an earlier draft hardcoded state=ShockState.ONSET here
                # instead of running the onset bar through _classify() like every other bar -
                # silently bypassing waterfall rules 1-5 (NORMALIZING/REVERSAL/ABSORPTION), which
                # the module docstring (section 5) documents as applying at every k, including
                # k==0. Under any sane config (all thresholds > 0) rules 1-5 cannot actually match
                # at k==0 (proven in the phase report), so this changes no observable behavior for
                # normal configs - it only restores waterfall consistency for degenerate ones
                # (e.g. a reversal/absorption threshold of exactly 0.0).
                state = self._classify(self._active, cfg)
            else:
                return self._snapshot_none(timestamp, magnitude_raw_pts, normalized_magnitude, range_expansion_atr,
                                            regime, regime_strength, transmission_state, transmission_available,
                                            vol_state_is_shock)
        else:
            ev = self._active
            ev.k += 1
            ev.cumulative_displacement_atr += signed_return_atr
            ev.max_excursion_atr = max(ev.max_excursion_atr, max(0.0, ev.onset_sign * ev.cumulative_displacement_atr))
            state = self._classify(ev, cfg)

        ev = self._active
        assert ev is not None
        cum = ev.cumulative_displacement_atr
        max_exc = ev.max_excursion_atr
        # code-review finding: this was previously re-derived inline here, duplicating the
        # identical formula inside _classify() - a single shared helper removes the risk of the
        # two copies silently drifting apart under a future threshold/formula change.
        adverse_exc, retracement = self._retracement(ev)

        # velocity: this bar's own incremental (signed, ATR-normalized) contribution to the
        # tracked event - identical formula whether this bar created the event (k==0, where it
        # equals onset_displacement_atr by construction) or extended it (k>=1).
        # acceleration: change vs. the PREVIOUS in-event bar's own velocity - undefined (0.0) on
        # the onset bar itself, since there is no prior in-event bar to difference against.
        velocity_atr = signed_return_atr
        acceleration_atr = 0.0 if ev.k == 0 else (velocity_atr - ev.prev_velocity_atr)
        ev.prev_velocity_atr = velocity_atr

        confidence = self._confidence(
            magnitude_atr=abs(ev.onset_displacement_atr),
            regime_strength=regime_strength,
            regime_available=regime_available,
            transmission_available=transmission_available,
            vol_state_is_shock=vol_state_is_shock,
        )

        # code-review finding: this gate must match confidence's own cross_asset_factor gate
        # (transmission_available alone) exactly - an earlier draft additionally required
        # transmission_state is not None here but not in _confidence, so a caller passing
        # transmission_available=True without transmission_state got confidence computed as if
        # cross-asset evidence were present while cross_asset_confirmation still read None
        # (looked unavailable) - an internally inconsistent snapshot.
        cross_asset_confirmation: Optional[bool] = None
        if transmission_available:
            cross_asset_confirmation = (transmission_direction != 0 and
                                         (transmission_direction > 0) == (ev.onset_sign > 0))

        snap = ShockDNASnapshot(
            timestamp=timestamp,
            valid=True,
            data_quality_ok=True,
            data_quality_reason="",
            shock_detected=True,
            shock_state=state,
            direction=ev.onset_sign,
            magnitude_raw_pts=magnitude_raw_pts,
            normalized_magnitude=normalized_magnitude,
            event_magnitude_atr=abs(cum),
            range_expansion_atr=range_expansion_atr,
            velocity_atr=velocity_atr,
            acceleration_atr=acceleration_atr,
            persistence_bars=ev.k,
            max_excursion_atr=max_exc,
            max_adverse_excursion_atr=adverse_exc,
            retracement_fraction=retracement,
            follow_through=(state == ShockState.FOLLOW_THROUGH),
            absorption=(state == ShockState.ABSORPTION),
            recovery=(state == ShockState.NORMALIZING and abs(cum) <= self.config.normalization_floor_atr),
            volatility_engine_shock=vol_state_is_shock,
            regime=regime,
            regime_strength=regime_strength,
            information_transmission_state=transmission_state,
            transmission_available=transmission_available,
            cross_asset_confirmation=cross_asset_confirmation,
            confidence=confidence,
        )

        if state == ShockState.NORMALIZING:
            self._active = None

        return snap

    # ------------------------------------------------------------------
    # internal helpers
    # ------------------------------------------------------------------

    @staticmethod
    def _retracement(ev: _ActiveEvent) -> tuple[float, float]:
        """(adverse_exc, retracement) for the given event's CURRENT state - the single
        definition shared by _classify() and update(), so the two never drift apart."""
        adverse_exc = max(0.0, ev.max_excursion_atr - ev.onset_sign * ev.cumulative_displacement_atr)
        retracement = (adverse_exc / ev.max_excursion_atr) if ev.max_excursion_atr > EPS else 0.0
        return adverse_exc, retracement

    @classmethod
    def _classify(cls, ev: _ActiveEvent, cfg: ShockDNAConfig) -> ShockState:
        k = ev.k
        onset_sign = ev.onset_sign
        cum = ev.cumulative_displacement_atr
        max_exc = ev.max_excursion_atr
        adverse_exc, retracement = cls._retracement(ev)

        if k >= cfg.lifecycle_bars:
            return ShockState.NORMALIZING
        if abs(cum) <= cfg.normalization_floor_atr and k >= cfg.min_decay_bars:
            return ShockState.NORMALIZING
        if onset_sign * cum <= -cfg.reversal_min_magnitude_atr:
            return ShockState.REVERSAL
        if retracement >= cfg.reversal_retracement_frac:
            return ShockState.REVERSAL
        if retracement >= cfg.absorption_retracement_frac:
            return ShockState.ABSORPTION
        if k == 0:
            return ShockState.ONSET
        if k <= cfg.impulse_bars and onset_sign * cum >= max_exc - EPS:
            return ShockState.IMPULSE
        if onset_sign * cum >= abs(ev.onset_displacement_atr) * cfg.follow_through_mult:
            return ShockState.FOLLOW_THROUGH
        return ShockState.ABSORPTION

    def _confidence(self, *, magnitude_atr: float, regime_strength: float, regime_available: bool,
                     transmission_available: bool, vol_state_is_shock: bool) -> float:
        cfg = self.config
        sample_factor = min(1.0, self._bars_sampled / (cfg.min_history_bars * 2.0))
        quality_factor = 1.0  # gated true already, by construction of this call path
        magnitude_factor = min(1.0, magnitude_atr / (cfg.onset_threshold_atr * 2.0))
        consistency_factor = 1.0  # OHLC/ATR sanity already checked before this call path
        cross_asset_factor = 1.0 if transmission_available else 0.6
        # regime_available (NOT truthiness of regime_strength) gates this factor - a genuinely
        # reported regimeConfidence of exactly 0.0 must gate confidence down hard, not be
        # mistaken for "no regime data supplied" and bumped up to the 0.5 default (a real defect
        # caught and fixed during this phase's own adversarial self-review - see the phase report).
        regime_certainty_factor = min(1.0, max(0.0, regime_strength / 100.0)) if regime_available else 0.5
        # CVolatilityEngine's own SHOCK state is a mild corroborating factor only (per file header
        # section 1): its ABSENCE does not crater confidence (ATR-acceleration is a lagging, smoothed
        # signal that a fresh single-bar event may not yet have triggered), but its PRESENCE is one
        # more independent piece of evidence quality, consistent with the gated-minimum convention.
        vol_corroboration_factor = 1.0 if vol_state_is_shock else 0.85
        return 100.0 * min(sample_factor, quality_factor, magnitude_factor, consistency_factor,
                            cross_asset_factor, regime_certainty_factor, vol_corroboration_factor)

    def _snapshot_unavailable(self, timestamp, state: ShockState, data_quality_ok: bool, reason: str,
                               regime, regime_strength, transmission_state, transmission_available,
                               vol_state_is_shock: bool) -> ShockDNASnapshot:
        return ShockDNASnapshot(
            timestamp=timestamp, valid=False, data_quality_ok=data_quality_ok, data_quality_reason=reason,
            shock_detected=False, shock_state=state, direction=0,
            magnitude_raw_pts=0.0, normalized_magnitude=0.0, event_magnitude_atr=0.0, range_expansion_atr=0.0,
            velocity_atr=0.0, acceleration_atr=0.0, persistence_bars=0,
            max_excursion_atr=0.0, max_adverse_excursion_atr=0.0, retracement_fraction=0.0,
            follow_through=False, absorption=False, recovery=False,
            volatility_engine_shock=vol_state_is_shock,
            regime=regime, regime_strength=regime_strength,
            information_transmission_state=transmission_state, transmission_available=transmission_available,
            cross_asset_confirmation=None,
            confidence=0.0,
        )

    def _snapshot_none(self, timestamp, magnitude_raw_pts, normalized_magnitude, range_expansion_atr,
                        regime, regime_strength, transmission_state, transmission_available,
                        vol_state_is_shock) -> ShockDNASnapshot:
        return ShockDNASnapshot(
            timestamp=timestamp, valid=True, data_quality_ok=True, data_quality_reason="",
            shock_detected=False, shock_state=ShockState.NONE, direction=0,
            magnitude_raw_pts=magnitude_raw_pts, normalized_magnitude=normalized_magnitude,
            event_magnitude_atr=0.0, range_expansion_atr=range_expansion_atr,
            velocity_atr=0.0, acceleration_atr=0.0, persistence_bars=0,
            max_excursion_atr=0.0, max_adverse_excursion_atr=0.0, retracement_fraction=0.0,
            follow_through=False, absorption=False, recovery=False,
            volatility_engine_shock=vol_state_is_shock,
            regime=regime, regime_strength=regime_strength,
            information_transmission_state=transmission_state, transmission_available=transmission_available,
            cross_asset_confirmation=None,
            confidence=0.0,
        )
