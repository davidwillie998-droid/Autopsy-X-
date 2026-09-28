# Phase 3 Report — Regime Engine + Volatility × Seriality Engine

**Authorization:** "PHASE 3 AUTHORIZATION: REGIME ENGINE + VOLATILITY/SERIALITY
ENGINE," confirming Phase 2 (commit `f9fd40a`) and authorizing this phase only.

---

## 1. Built

Two new, dormant, signal-only engines:

- **Regime Engine** (`RegimeClassifierEngine.mqh`, `CRegimeClassifierEngine`) —
  produces the direction-aware R1-R8 classification (Persistent Bullish/
  Bearish Trend, Bullish Unstable, Bearish Transition, Range/Chop,
  Volatility Shock, Information Conflict, Structural Break) by fusing
  already-computed reads from `CRegimeEngine`, `CVolatilityEngine`,
  `CMomentumEngine`, and Phase 3a's `SAxRegimeIntelligence` output.
- **Volatility × Seriality Engine** (`VolatilitySerialityEngine.mqh`,
  `CVolatilitySerialityEngine`) — produces the 7-state vol/return-
  seriality classification (low-vol-persistent/random, high-vol-
  trending/mean-reverting, volatility shock, vol-expansion +
  acceleration/reversal) by combining `CVolatilityEngine`'s existing
  classification with a new bar-level return-autocorrelation/
  directional-persistence/reversal-frequency computation that exists
  nowhere else in this codebase.

Also built, before any code was written for this phase: **Phase 3a**
(commit `07e69e2`, previous session turn), which this phase's Regime
Engine directly consumes rather than duplicating.

## 2. Files created

- `MQL5/Include/AutopsyX/RegimeClassifierEngine.mqh`
- `MQL5/Include/AutopsyX/VolatilitySerialityEngine.mqh`
- `docs/PHASE3_REGIME_VOLATILITY_REPORT.md` (this file)

## 3. Files modified

**None.** No existing file — live or dormant — was changed. `Regime.mqh`,
`MacroRegime.mqh`, `Momentum.mqh`, `VolatilityEngine.mqh`, and
`RegimeIntelligenceEngine.mqh` are all read-only inputs, unmodified.
Confirmed by `git status --short`: only the two new files above are
untracked; nothing else shows as modified.

## 4. Interfaces / functions

```
enum ENUM_AX_REGIME_CLASS { R1..R8, AX_RC_UNAVAILABLE }
struct SAxRegimeClassification { regime, regimeConfidence, regimeAgeBars,
  hasPreviousRegime, previousRegime, transitionDetected,
  transitionDescription, supportingFactors[], conflictingFactors[],
  dataQualityOk, dataQualityReason, timestamp }

class CRegimeClassifierEngine
{
  void Configure(int minAgeForPersistent, double minStabilityForPersistent,
                 double minMomentumForPersistent, double structuralBreakVolRatioMult);
  bool Sample(string symbol, ENUM_TIMEFRAMES regimeTimeframe,
              bool dataIntegrityOk, string dataIntegrityReason,
              const CRegimeEngine&, const CVolatilityEngine&,
              const CMomentumEngine&, const SAxRegimeIntelligence &regimeIntel,
              SAxRegimeClassification &out);
}

enum ENUM_AX_VOL_SERIALITY_CLASS { 7 states, AX_VS_UNAVAILABLE }
struct SAxVolatilitySeriality { atrPrice, volPercentile, volAccelerationPct,
  volState, returnAutocorrelation, directionalPersistence,
  reversalFrequencyPct, sampleSize, classification, classificationReason,
  dataQualityOk, dataQualityReason, timestamp }

class CVolatilitySerialityEngine
{
  void Configure(int lookbackBars, ENUM_TIMEFRAMES barTimeframe,
                 int minSampleSize, double expansionAccelPct);
  bool Sample(string symbol, bool dataIntegrityOk, string dataIntegrityReason,
              const CVolatilityEngine&, SAxVolatilitySeriality &out);
}
```

## 5. Dependencies

Regime Engine: `CRegimeEngine` (live/wired), `CVolatilityEngine` (dormant),
`CMomentumEngine` (live/wired), `CRegimeIntelligenceEngine`'s output
(Phase 3a, dormant) — all read-only. Volatility × Seriality Engine:
`CVolatilityEngine` (dormant) — read-only, plus its own closed-bar
`CopyClose` read. Neither calls `CTrade`, neither is `#include`d by
`AutopsyX_FlipDemon_Extreme.mq5` — confirmed by grep, zero matches for
either class name in the main file.

## 6. Verification

Balance-check + code review only. **Compilation not verified: MQL5
compiler unavailable in this environment.** No MetaEditor, no MT5
Strategy Tester run — same constraint as every prior phase
(`docs/VERIFICATION_STATUS.md`).

## 7. Tests performed

- Balance check (brace/paren/bracket) on each new file individually,
  after every fix round.
- Full-repo balance check after both files were finalized: **60/60**
  `.mqh`/`.mq5` files in `MQL5/` — OK, zero mismatches.
- Code review, multiple rounds per file (high → fix → medium verify →
  fix, repeated until each verify pass came back clean or only
  low-severity/documentation items remained).
- Python regression suite (unaffected by these files, run as a
  regression check): `python -m pytest python/tests/` — 27 passed,
  unchanged.
- Manual trace of edge cases during review: zero-return bars (doji
  closes) in the autocorrelation/persistence/reversal math, a
  `minSampleSize > lookbackBars` misconfiguration, a stale
  `regimeIntel` snapshot being fused into a fresh bar, `STRONG_TREND ⇄
  TREND` oscillation under Regime.mqh's own no-hysteresis `volRatio>=
  1.15` gate, and a transient `CopyClose` failure on a genuinely new bar.

## 8. Test results

All balance checks: clean. All code-review rounds: findings fixed and
re-verified (see items 9/10 below). Python suite: 27/27 passing,
unchanged from before this phase.

## 9. Bugs discovered

**Regime Engine** (5 real issues across 3 review rounds):
1. `STRONG_TREND` confidence scored only the `r2` margin, never
   `volRatio>=1.15` — the actual deciding threshold vs plain `TREND`
   — inverting confidence in both directions at the margins.
2. The "established" (persistent-trend) check used
   `CMomentumEngine::PersistenceRatio()`, a direction-agnostic
   magnitude, not confirmation that tick momentum agreed with the
   bar's own slope direction.
3. "established" hard-gated on `AX_REGIME_STRONG_TREND` alone, so a
   long-held, highly stable plain `TREND` regime could never be
   classified R1/R5, permanently mislabeled as unstable/in-transition.
4. **(Deepest finding)** Fixing #3 by widening the gate to include
   `TREND` was undermined because the age/stability inputs it relied
   on (`regimeIntel.regimeAgeBars`/`regimeStability`) reset on every
   exact `STRONG_TREND ⇄ TREND` enum flip — which `Regime.mqh`'s own
   `volRatio>=1.15` gate has no hysteresis band against, so it happens
   routinely even with an unchanged trend direction. This reproduced
   the same "permanently mislabeled" failure via a different
   mechanism.
5. `Sample()` never validated that the caller-supplied `regimeIntel`
   snapshot actually belonged to the bar being classified, so a caller
   ordering bug could silently fuse a stale prior-bar snapshot into a
   fresh classification.
Plus 2 lower-severity items: the momentum-floor default (0.55) sat
below `PersistentBull()/PersistentBear()`'s own internal 0.6 floor,
making part of the "direction AND magnitude" check a no-op at default;
and R7's confidence formula was a disguised constant, not a genuine
computed margin, despite reading as one.

**Volatility × Seriality Engine** (4 real issues, 1 review round):
1. A bar's return was pushed into the rolling autocorrelation window
   even when the caller flagged that tick's data integrity as bad,
   letting one bad-data bar skew every downstream reading for up to
   `lookbackBars` future samples.
2. `Configure()` didn't validate `minSampleSize <= lookbackBars`, so a
   misconfiguration could make `dataQualityOk` permanently
   unreachable with no signal why.
3. `AX_VOL_NORMAL` (a real, distinct `CVolatilityEngine` state) was
   silently folded into the "low vol" classification bucket and
   labeled as such.
4. A transient `CopyClose` failure on a genuinely new bar permanently
   advanced the "already processed" marker, losing that bar's return
   forever instead of retrying.

## 10. Bugs fixed

All 9 issues above, fixed and re-verified in a subsequent review round
each (see the two files' own inline comments at each fix site for the
full reasoning). One documentation-only nit (a forward reference to
this very report file, which didn't exist yet at review time) resolved
itself once this report was written — no code change needed.

## 11. Regression results

- No existing module was modified (confirmed by `git status --short` —
  only the two new files are untracked).
- No existing signal was altered — `Regime.mqh`, `MacroRegime.mqh`,
  `Momentum.mqh`, `VolatilityEngine.mqh` are read-only inputs to both
  new engines.
- No risk rule was weakened — `RiskEngine.mqh`/`EmergencyControls.mqh`
  are untouched and unreferenced by either new file.
- No order logic was changed — neither new file calls `CTrade` or
  touches order state; confirmed by grep, zero matches.
- No journal fields were broken — `TradeAutopsy.mqh`/`Statistics.mqh`
  are untouched and unreferenced.
- No stale state can silently influence decisions — the Regime
  Engine's `regimeIntel` freshness check (bug #5 above) and the
  Volatility Engine's dataIntegrityOk-gated ring-buffer push (bug #1
  above) both exist specifically to enforce this.
- Unavailable data fails safely — both engines report a dedicated
  `AX_RC_UNAVAILABLE`/`AX_VS_UNAVAILABLE` state (confidence 0, no
  classification fabricated) rather than guessing, on data-integrity
  failure, insufficient history, or a stale snapshot.
- Confirmed neither new class name appears anywhere in
  `AutopsyX_FlipDemon_Extreme.mq5` (grep, zero matches) — the live EA's
  `OnInit`/`OnTick`/`OnTimer` are byte-for-byte unchanged by this phase.

## 12. Ablation status

**Not performed — no manufactured ablation study.** Neither engine has
any caller anywhere in the codebase (confirmed by grep) and neither
influences a single live trading decision. A treatment/control
comparison requires a decision the treatment could plausibly change;
there is none here to compare against. Manufacturing one (e.g. wiring
a synthetic test harness solely to produce an ablation number) would
be exactly the speculative infrastructure this phase was told not to
build. Ablation testing becomes meaningful once a later phase's Master
Decision Engine actually reads either engine's output and a backtest
harness can run the live EA with and without that read — deferred
honestly, not faked.

## 13. Limitations

**Regime Engine:**
- `regimeConfidence` is an engineering-design heuristic, not a
  statistically fitted probability (same convention as
  `AlphaEngine::RegimeAlignmentScore`).
- R6 (`80.0`), R7 (`100.0`), and R8 (`55.0`) confidences are fixed
  tiers, not computed margins — `CVolatilityEngine`'s own shock
  threshold isn't publicly exposed, and `macroAgreementScore` is only
  3-valued, so no finer-grained margin is honestly derivable from
  either.
- R8 "Structural Break" is a self-contained proxy (CHAOTIC at double
  `Regime.mqh`'s own erratic threshold), explicitly **not** the future
  Shock DNA Engine (shock type/duration/recovery-time/MAE-MFE) — that
  engine was not built, per the phase's own stop condition.
- R7 "Information Conflict" is a same-bar directional agreement check
  reusing Phase 3a's existing macro cross-check, explicitly **not**
  the future Causality/Information Transmission Engine (lead-lag,
  rolling/lagged correlation, information decay) — also not built.
- The requested taxonomy is asymmetric by its own wording (R2 "Bullish
  Unstable" vs. R4 "Bearish Transition," no matching symmetric pair);
  this engine does not invent the two missing labels — any
  non-persistent bullish reading reports R2, any non-persistent
  bearish reading reports R4, exactly matching the given label set.
- CHAOTIC readings that don't clear R8's threshold, and a
  zero-slope BREAKOUT (rare), fall through to R3 Range/Chop as the
  closest available bucket — an approximation, not a precise semantic
  fit.
- The `AX_REGIMECLASSIFIER_ERRATIC_MIRROR` constant (`2.2`) duplicates
  a private literal inside `Regime.mqh`'s own `Classify()`, which
  exposes no public accessor for it. A future change to that literal
  in `Regime.mqh` requires a human to notice and update this file too
  — there is no compiler-enforced link between the two.

**Volatility × Seriality Engine:**
- `returnAutocorrelation`/`directionalPersistence`/
  `reversalFrequencyPct` are computed over a single configurable
  window (default 50 bars) with no significance testing — this phase's
  own instruction is explicit that no trading-alpha claim is made here,
  only whether these measurements carry useful state information for
  later phases.
- `AX_VOL_NORMAL` is folded into the "low vol" classification bucket
  by design (the requested 7-state taxonomy has no separate "normal"
  slot) — the real `volState` is always embedded in
  `classificationReason`, so the distinction is never actually hidden,
  but a caller reading only the top-level classification string could
  still be misled if they don't also check `classificationReason` or
  `volState`.
- `directionalPersistence` doubles as "trend persistence" (spec
  wording) rather than being a second, independently-derived measure —
  building a genuinely different one would duplicate `CRegimeEngine`'s
  own `R2`, already used for that purpose in the Regime Engine.
- `CMomentumEngine::PersistenceRatio()` is deliberately **not** reused
  here — it measures tick-level (≈30-tick window) persistence, a
  different statistical object on a different time scale than this
  engine's bar-level return serial dependence. Stated explicitly to
  prevent the two being conflated.

## 14. Compilation status

**Compilation not verified: MQL5 compiler unavailable in this
environment.**

## 15. Commit hash

Recorded after this report is committed (see the commit that includes
this file — its own hash is `HEAD` at push time, referenced in the
commit message itself since a file cannot self-reference its own
future hash).

## 16. Recommended next step

Per the stop condition, **none** — this phase is complete and the
session stops here pending explicit Phase 4 review and sign-off. No
Causality Engine, Shock DNA, Information Surprise, Ensemble, Market
Memory, State Transition, Tradeability, Execution Alpha, Model Health,
or Self-Falsification work has been started, referenced, or scaffolded
anywhere in this phase's two files.

If and when Phase 4 is authorized, the natural candidates (per the
Phase 1 audit's reuse-first findings, not yet re-confirmed for Phase 4
specifically) are: extending `TradePermissionMatrix.mqh` toward the
Master Decision Engine's `ALLOW_LONG/ALLOW_SHORT/WAIT/REDUCE/PAUSE/
CLOSE/NO_TRADE/MODEL_DISABLED` vocabulary (it already implements a
15-gate HARD/SOFT decision ladder), and exposing `AlphaEngine`/
`PriceImpactEngine`'s existing EV-cost logic under explicit
Tradeability naming — both flagged in the original audit as the
strongest reuse cases, ahead of any genuinely new module.
