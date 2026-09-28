# Phase 4B: Shock DNA / Shock Characterization Engine — Engineering Report

**Approved baseline going in:** commit `6a364c8` (Phase 4A: PASS WITH LIMITATIONS,
observational only, unmodified by this phase).
**Scope:** Phase 4B only — a new, isolated, unwired observational engine that
characterizes single-bar market shock events. No trading logic, no risk
logic, no Phase 5 work, no new taxonomies, no external data sources.

---

## 1. Existing architecture audited

Before writing any code, the following existing infrastructure was read and
confirmed authoritative (grep + full-file reads):

- `Defs.mqh` — `ENUM_AX_VOLATILITY_STATE` already contains `AX_VOL_SHOCK`
  (comment: "a sudden, sharp spike distinct from a sustained HIGH/EXTREME
  regime"), mapped by `AxVolatilityStateToString()`.
- `VolatilityEngine.mqh` (`CVolatilityEngine`) — the authoritative ATR /
  5-state volatility taxonomy. `State()`/`CurrentAtr()`/`PercentileRank()`/
  `AccelerationPct()` reused; no re-derivation.
- `CrisisEngine.mqh` — read and confirmed to be a *different* concept
  (ongoing systemic severity, not a single-event characterization); correctly
  left alone, not reused and not duplicated.
- `RegimeClassifierEngine.mqh` (`CRegimeClassifierEngine`, Phase 3) — the
  authoritative 9-state direction-aware regime taxonomy
  (`ENUM_AX_REGIME_CLASS`) and `SAxRegimeClassification`. Reused verbatim as
  a caller-supplied input; no second regime classifier built.
- `InformationTransmissionEngine.mqh` (`CInformationTransmissionEngine`,
  Phase 4A) — `ENUM_AX_TRANSMISSION_STATE` and
  `SAxInformationTransmissionSnapshot` (fields incl. `valid`, `state`,
  `direction`, `dataQualityOk`). Reused verbatim; **this file was not
  modified**, per the phase's explicit constraint.
- `DataIntegrity.mqh` (`CDataIntegrityEngine`) — the authoritative
  feed-quality gate (`Check()` → `dataIntegrityOk`/`reasonOut`). Taken as a
  caller-supplied `Sample()` parameter, matching every other Phase 3/4A
  engine's own signature; not re-derived.
- `Momentum.mqh` (`CMomentumEngine`) — read in full. Its
  `Velocity()`/`Acceleration()` are **tick-arrival-rate** measures (ticks
  per second, computed over a rolling window of raw ticks that can straddle
  a still-forming bar) — a genuinely different statistical object from a
  bar-level, ATR-normalized price-velocity. Reusing it would have dressed up
  a tick-level, intrabar-eligible measurement as a bar-closed-only one — the
  same distinction `VolatilitySerialityEngine.mqh` already drew against
  `CMomentumEngine.PersistenceRatio()`. Not reused; Shock DNA computes its
  own honestly-labeled bar-level equivalent instead (see §3).
- `VolatilitySerialityEngine.mqh` and `RegimeClassifierEngine.mqh` — read in
  full as the direct structural templates for the new engine (Sample()
  taking already-computed inputs, new-bar gating via `iTime(...,1)`, own
  closed-bar `CopyClose`/`CopyHigh`/`CopyLow` reads at shift≥1, ring-buffer-
  free bounded state, `dataQualityOk`/`dataQualityReason` convention).
- `Regime.mqh` — checked specifically whether its `AX_REGIMECLASSIFIER_
  ERRATIC_MIRROR = 2.2` threshold (mirrored in `RegimeClassifierEngine.mqh`)
  could be reused for the onset threshold. Confirmed it measures a
  **different quantity** (`CurrentAtr()/AverageAtr()` — is volatility itself
  elevated) from what Shock DNA needs (a single bar's own net displacement
  relative to ATR). Not borrowed — see §2's honesty note.

No duplicate volatility taxonomy, regime taxonomy, data-integrity system, or
correlation/transmission engine was created.

## 2. Exact shock definition

**Primary — onset magnitude:**

```
onset_magnitude_atr(t) = |close(t) − close(t−1)| / atr_price(t)
```

A shock **onset** fires at bar *t* when no event is currently tracked and
`onset_magnitude_atr(t) ≥ onset_threshold_atr` (default **1.5**,
`Configure()`-able).

- **Close-to-close, not high-low range** — a bar can have a huge intrabar
  range yet close back near where it opened; that is absorption/a failed
  push, not a shock that repriced the market. Range is tracked separately
  (`range_expansion_atr`), never folded into the trigger.
- **ATR-relative, not fixed-point** — cancels price scale and volatility
  regime (verified in §16/§17: identical ratio, identical state, across a
  50× price-scale difference and across differing ATR regimes with
  differing raw point-deltas).
- **Honesty on the threshold's own calibration** — this sandboxed
  environment has no historical price feed to empirically fit a tail
  percentile. `1.5x ATR` is a **documented, configurable engineering
  choice**, justified only by the normalization argument above — not a
  backtested value, and not borrowed from `Regime.mqh`'s `2.2` (which
  measures a different quantity, ATR-vs-its-own-average, not a single bar's
  displacement-vs-ATR; borrowing that numeral would have misrepresented
  reuse). A caller with real historical data is expected to calibrate it.

**Secondary descriptors** (always computed when data is usable):
`magnitude_raw_pts` (raw points, debug-only, not scale-aware),
`range_expansion_atr`, `direction` (fixed at onset).

**Not measured:** volume/tick-volume anomaly — no existing, independently
validated tick/real-volume reliability layer exists to build on; adding one
here would duplicate a DataIntegrity concern. Left absent, not fabricated.

## 3. Mathematical specification

State per tracked event (bars-since-onset `k`):

```
onset_sign  = sign(onset_displacement_atr)
cum(k)      = cumulative ATR-normalized signed displacement since onset
max_exc(k)  = running max of max(0, onset_sign · cum(j)),  j ≤ k
adverse(k)  = max_exc(k) − onset_sign · cum(k)                (≥ 0)
retracement(k) = adverse(k) / max_exc(k)   if max_exc(k) > ε else 0
velocity(k)     = this bar's own signed ATR-normalized return (k=0: = onset_displacement_atr by construction)
acceleration(k) = velocity(k) − velocity(k−1)   (0 at k=0: no prior in-event bar)
```

Single-event tracking: only one event is ever tracked at a time; a second
large bar while an event is active extends/reverses that SAME event rather
than spawning a new one (§16, tests 21/22).

## 4. Shock lifecycle

`ONSET (k=0) → IMPULSE (extending, k≤impulse_bars) → FOLLOW_THROUGH
(extended, low retracement) → [ABSORPTION | REVERSAL] → NORMALIZING
(terminal: lifecycle cap or decayed near zero)`. The engine is fed one
closed bar at a time; each call reads only that bar plus its own prior
accumulated event state — there is no separate "completed shock" structure
with privileged future access (§13).

## 5. State taxonomy

9 mutually exclusive states: `UNKNOWN`, `INSUFFICIENT_DATA`, `NONE`,
`ONSET`, `IMPULSE`, `FOLLOW_THROUGH`, `ABSORPTION`, `REVERSAL`,
`NORMALIZING`. Full definitions in `shock_dna.py` §4.

## 6. State waterfall (deterministic, first match wins)

```
1. k ≥ lifecycle_bars                                        → NORMALIZING
2. |cum| ≤ normalization_floor_atr and k ≥ min_decay_bars     → NORMALIZING
3. onset_sign·cum ≤ −reversal_min_magnitude_atr               → REVERSAL
4. retracement ≥ reversal_retracement_frac                    → REVERSAL
5. retracement ≥ absorption_retracement_frac                  → ABSORPTION
6. k == 0                                                     → ONSET
7. k ≤ impulse_bars and onset_sign·cum ≥ max_exc − ε          → IMPULSE
8. onset_sign·cum ≥ |onset_displacement_atr|·follow_through_mult → FOLLOW_THROUGH
9. else (stalled: not retracing, not extending, not decayed)  → ABSORPTION
```

Applied uniformly at every `k`, **including k=0** — a genuine defect found
during code-review (see §21) had the onset bar bypass this waterfall
entirely; fixed in both Python and MQL5.

## 7. Snapshot schema

`SAxShockDNASnapshot` (MQL5) / `ShockDNASnapshot` (Python): `timestamp`,
`valid`, `dataQualityOk`/`dataQualityReason`, `shockDetected`, `shockState`,
`direction`, `magnitudeRawPts`, `normalizedMagnitude`, `eventMagnitudeAtr`,
`rangeExpansionAtr`, `velocityAtr`, `accelerationAtr`, `persistenceBars`,
`maxExcursionAtr`, `maxAdverseExcursionAtr`, `retracementFraction`,
`followThrough`, `absorption`, `recovery`, `volatilityEngineShock`,
`regime`, `regimeStrength`, `transmissionState`, `transmissionAvailable`,
`crossAssetConfirmation(Available)`, `confidence`. Every field has an exact
definition in `shock_dna.py`'s module docstring §3/§7; none added merely for
completeness.

## 8. Confidence methodology

```
confidence = 100 · min(sample_factor, quality_factor, magnitude_factor,
                        consistency_factor, cross_asset_factor,
                        regime_certainty_factor, vol_corroboration_factor)
```

A **gated minimum**, never a blind average (matching
`TradePermissionMatrix.mqh`/`InformationTransmissionEngine.mqh`/
`RegimeClassifierEngine.mqh`'s own convention). Not a probability, never
called one. `test_confidence_not_driven_by_magnitude_alone` proves a
20x-ATR single bar with thin sample history is gated down to exactly the
`sample_factor` ceiling, not driven up by magnitude alone.

## 9. Normalization methodology

ATR-relative ratios throughout (§2). Verified directly: identical
`normalized_magnitude` and identical resulting state across a 50× price
scale difference (test_23) and across differing ATR regimes with raw
point-deltas that do/don't scale accordingly (test_24).

## 10. Regime integration

Caller-supplied `SAxRegimeClassification` (Phase 3) read for `regime` +
`regimeConfidence` as descriptive context only. `test_17` proves regime
data is a pure passthrough — it never affects `shockState` or
`normalized_magnitude`, only `confidence` (by design, via
`regime_certainty_factor`). No predictiveness inferred from regime-
conditional behavior differences, per the phase's own instruction.

## 11. Cross-asset integration

Caller-supplied `SAxInformationTransmissionSnapshot` (Phase 4A) read
descriptively; `cross_asset_confirmation` is `True`/`False`/unavailable
based purely on whether the transmission engine's own reported direction
agrees with this event's onset direction — descriptive only, no
causal/predictive claim (tests 18/19).

## 12. Missing/stale-data handling

`dataIntegrityOk`/`reason` are caller-supplied (never re-derived). A bad or
unusable bar (`UNKNOWN`) does not advance the engine's own readiness
counter or the active event's history — excluded entirely, never
clipped/filled/fabricated (tests 12/13/16). No ad-hoc outlier filter was
added (§9 of `shock_dna.py`'s docstring) — that is DataIntegrity's job, and
large-but-real moves are exactly what this engine exists to characterize.

## 13. Look-ahead protection

Verified directly, not merely assumed: `test_15_future_data_injection_
never_changes_past_snapshots` replays an identical bar prefix with extra
future bars appended and asserts byte-for-byte (dataclass `==`) equality of
every snapshot at the shared indices. Passes.

## 14. Deterministic tests

**43 tests** in `test_shock_dna.py`: the 24 named tests from the
authorization (§13) verbatim, plus explicit boundary-condition tests for
every waterfall threshold (absorption/reversal-retracement/reversal-
magnitude/lifecycle-cap, tested at their exact numeric boundary), plus
confidence-gating regression tests, plus the false-positive/sensitivity
experiments below. All pass (see §23 for exact counts).

## 15. Null/false-positive experiments

Four null structures, multiple independently-seeded trials each, **exact
reported rates** (no synthetic-rate-equals-real-market-rate claim made):

| Null model | Seeds × bars | Onsets | Rate |
|---|---|---|---|
| A. IID Gaussian | 20 × 300 = 6000 | 226 | **3.77%** |
| B. AR(1) autocorrelated | 10 × 300 = 3000 | 126 | **4.20%** |
| C. Heteroskedastic (regime-switching variance) | 10 × 300 = 3000 | 132 | **4.40%** |
| D. GARCH(1,1)-like clustering (lagged, causal ATR proxy) | 10 × 300 = 3000 | 130 | **4.33%** |

These are synthetic-null onset rates under this engine's default config
(`onset_threshold_atr=1.5`), not a claim about real-market false-positive
rates — no historical dataset was available in this environment to compute
the latter (see §2's honesty note).

## 16. Sensitivity experiments

Injected shock magnitude vs. detection rate (background noise σ=0.3 ATR,
40 fresh-seeded trials per magnitude, no tuning to shape the curve):

| Injected magnitude | Detection rate |
|---|---|
| 0.8× ATR | 0.000 (0/40) |
| 1.2× ATR | 0.000 (0/40) |
| 1.6× ATR | 1.000 (40/40) |
| 2.0× ATR | 1.000 (40/40) |
| 3.0× ATR | 1.000 (40/40) |

A clean step exactly at the configured 1.5× threshold — expected and
correct for a deterministic ATR-relative rule; characterization only, no
claim about real-market shock magnitude distributions.

## 17. Outlier behaviour

No filter added. A single outlier is characterized (test_10, `ONSET` then
lifecycle-tracked to `NORMALIZING`, calm bars unaffected). Multiple extreme
observations close together are tracked as either a single continuing event
(same-direction, test_21) or the same event flipping into `REVERSAL`
(opposite-direction, test_22) — never silently merged or dropped, matching
the single-event-tracking design (§16 of the module docstring).

## 18. Python/MQL5 parity

`ShockDNAEngine.mqh`/`CShockDNAEngine` hand-ports `shock_dna.py`'s exact
formulas, defaults, and waterfall order — line-by-line cross-checked. Both
code-review-discovered defects (§21) were fixed identically in both files.
`SAxRegimeClassification`/`SAxInformationTransmissionSnapshot`'s natural
MQL5 zero-initialization (`dataQualityOk`/`valid` default `false`) was
confirmed to already match Python's corrected `regime_available=False` /
`transmission_available=False` defaults — no separate MQL5 fix was needed
for that defect, only the Python default. MQL5 compilation itself was not
executed (see §24); parity was verified by inspection and by mirroring
every formula and constant exactly.

## 19. Computational complexity

O(1) work per `Sample()`/`update()` call: no scans of historical arrays
beyond the active event's own incrementally-maintained running max/adverse-
max. Fixed, finite memory (one optional active-event record + a small
bars-sampled counter). New-bar-gated (`iTime(...,1)` guard), matching every
other engine in this build. No external API, no ML, no unbounded array.

## 20. Coupling audit

```
grep -rn "ShockDNA" MQL5/Experts/          → (empty)
```
Zero references anywhere in the live EA. The file is not `#include`'d by
`AutopsyX_FlipDemon_Extreme.mq5` or any other engine that feeds the live
decision path. Confirmed via repo-wide grep, not by inspection alone.

## 21. Defects discovered (adversarial self-review + two code-review passes)

1. **Onset bar bypassed the state waterfall.** `update()`/`Sample()`
   hardcoded `state = ONSET` at `k=0` instead of running it through
   `_classify()`/`Classify()`, silently skipping waterfall rules 1–5. Under
   any sane config (all thresholds > 0) this is provably unobservable
   (proven algebraically in the fix's own comment), but under a degenerate
   config (e.g. a retracement threshold of exactly 0.0) it diverged from
   the documented "first match wins, applies at every k" contract. **Fixed
   in both files** — the onset bar now calls the same classifier.
2. **`_snapshot_unavailable`/`_snapshot_none` accepted `transmission_
   available` but never stored it.** `ShockDNASnapshot` had no
   corresponding field at all — a genuine parity gap against the MQL5
   struct, which already stored `transmissionAvailable`. **Fixed**: added
   the field to the Python dataclass, populated on all three construction
   paths, regression-tested.
3. **`regime_certainty_factor` used truthiness (`if regime_strength else
   0.5`) instead of an explicit availability flag.** A genuinely reported
   `regime_strength=0.0` (regime data IS available, classifier is just very
   uncertain) was indistinguishable from "no regime data supplied" and
   silently bumped up to the 0.5 default instead of correctly gating
   confidence to 0.0. **Fixed**: added an explicit `regime_available`
   parameter; MQL5 was structurally immune already
   (`regimeClass.dataQualityOk`, a real bool field, was always used, not a
   truthiness check on `regimeStrength`).
4. **`regime_available`'s own default was `True`**, inconsistent with
   `regime_strength`'s `0.0` default and with the sibling `transmission_
   available`'s `False` default — so a caller who omitted regime info
   entirely (a plausible real caller, since this engine is observational-
   only and may run with no regime engine wired up) got confidence silently
   forced to `0.0` on *every* detected shock. **Fixed**: default changed to
   `False`, matching `transmission_available`. MQL5 was already correct by
   construction (a default-constructed `SAxRegimeClassification` zero-
   initializes `dataQualityOk` to `false`).
5. **`cross_asset_confirmation`'s gate was inconsistent with `confidence`'s
   own `cross_asset_factor` gate** — the confirmation additionally required
   `transmission_state is not None`, while confidence's factor did not, so
   a caller supplying `transmission_available=True` without
   `transmission_state` got a snapshot that looked cross-asset-unavailable
   (`None`) while confidence was computed as if it were available. **Fixed**:
   both now gate on `transmission_available` alone. MQL5 was already
   consistent (no extra check existed there).
6. **Duplicated retracement/adverse-excursion formula** — computed once
   inside `_classify()`/`Classify()` and again immediately after in
   `update()`/`Sample()`, a maintenance hazard (a future threshold change
   applied to only one copy would silently desync classification from the
   reported `retracement_fraction` field). **Fixed**: extracted a single
   shared helper (`_retracement()` in Python, `RetracementOf()` in MQL5),
   used by both call sites in both files.
7. **Test defect (not an engine defect)**: `test_10`'s original decay loop
   fed flat (zero-delta) bars expecting them to decay `|cum|` toward the
   normalization floor — but a zero-return bar contributes nothing to
   cumulative displacement, so `|cum|` never changes on flat bars; the
   event only ever reaches `NORMALIZING` via the hard lifecycle cap in that
   scenario. **Fixed**: corrected the test's own expectation.
8. **Test defect (not an engine defect)**: the original `test_confidence_
   not_driven_by_magnitude_alone` left `regime_strength`/`regime_available`
   at defaults, so `regime_certainty_factor` was *already* 0.0 and alone
   zeroed confidence — the assertion passed for a reason unrelated to what
   it claimed to test, and would not have caught a broken magnitude gate.
   **Fixed**: rewrote to saturate every other factor to 1.0, isolating
   `sample_factor` as the provably binding gate, and asserting confidence
   equals exactly that computed ceiling.

## 22. Fixes applied

All eight items in §21 above, in both `shock_dna.py` and (where applicable)
`ShockDNAEngine.mqh`, each with an inline "code-review finding" comment at
the fix site and a dedicated regression test (Python) locking in the
corrected behavior. Full regression suite re-run after every fix.

## 23. Final test counts

- `python/tests/test_shock_dna.py`: **43 tests collected, 43 passed** (38
  distinct test functions; 5 additional parametrize cases in
  `test_sensitivity_onset_detection_by_injected_magnitude`).
- Full repo Python suite (`python/tests/`): **86 passed, 0 failed** (43
  Shock DNA + 15 Lead-Lag + existing smoke/backtest suites), confirming no
  regression anywhere else in the repo.
- Full-repo MQL5 balance-check sweep (brace/paren/bracket, string/comment-
  aware): every `.mqh`/`.mq5` file in `MQL5/` — **clean**, including the
  new `ShockDNAEngine.mqh`.

## 24. Compilation status

**MQL5 compilation not verified because no actual MQL5 compiler was
available in this build environment.** Balance-checking and two rounds of
code-review (`--level high` then `--level medium`) are static-analysis
steps, not a substitute for compilation, and are never represented as such.

## 25. Commit hash

`<to be filled in via a small follow-up commit once the real hash is
known, matching the established pattern from every prior phase>`

## 26. Final disposition

**PASS WITH LIMITATIONS.**

Rationale: the implementation is mathematically explicit, bounded, fully
deterministic-tested (43/43), look-ahead-protected (verified, not assumed),
confidence-gated per this codebase's own established convention, provably
decoupled from the live EA, and free of the QQQ/TQQQ/NDX/NQ/external-API/ML
scope violations this phase explicitly forbade. Two rounds of code review
found eight genuine issues (six real defects, two test defects); all were
fixed with regression tests, and the full suite was re-run to confirm no
new regressions. The **limitations** that keep this from an unqualified
PASS: (a) `onset_threshold_atr=1.5` and every other waterfall constant are
documented engineering choices, not empirically-calibrated values — no
historical price feed was available in this environment to fit them; (b)
the null-model onset rates in §15 characterize this engine's behavior on
*synthetic* data only and must not be read as real-market false-positive
rates; (c) MQL5 compilation itself was never executed, per §24, so MQL5-
specific compiler-level issues (if any) remain unverified beyond careful
manual parity review.

**Per the hard stop:** this engine is not wired into any trading decision,
does not modify risk/execution/entries/management/journal logic, does not
begin Phase 5, adds no external data sources, and does not touch
`InformationTransmissionEngine.mqh`. Awaiting explicit approval before any
further phase.
