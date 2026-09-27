# Phase 3a Report — Regime Intelligence

**Applies to:** `MQL5/Include/AutopsyX/RegimeIntelligenceEngine.mqh` (new,
205 lines).

**Correction to the Phase 1 audit, made before writing any code for this
phase, not after:** `docs/AUDIT_10X_MARKET_INTELLIGENCE.md` claimed no
R1-R8-style regime taxonomy existed in this codebase. That was wrong. The
audit's own interface grep used a pattern that matched a bare `ENUM_`
token followed by whitespace — every real enum name in this codebase is
`ENUM_AX_...` with no space after `ENUM_`, so the grep silently missed
every enum-typed accessor, including `CRegimeEngine::Regime()`, which
already returns a live, wired 9-state `ENUM_AX_REGIME` (`TREND`,
`STRONG_TREND`, `BREAKOUT`, `RANGE`, `MEAN_REVERSION`, `HIGH_VOL`,
`LOW_VOL`, `CHAOTIC`, `UNSAFE` — see `Defs.mqh`), already consumed by
`AlphaEngine`, `Dashboard`, and `PerformanceAttribution`. `CVolatilityEngine`
similarly already has a 5-state `ENUM_AX_VOLATILITY_STATE`
(`NORMAL`/`LOW`/`HIGH`/`EXTREME`/`SHOCK`). Building new, competing
taxonomies for either would have been exactly the duplicate-engine mistake
the audit itself warned against — caught by re-reading `Regime.mqh`'s
actual source before writing `RegimeIntelligenceEngine.mqh`, not after.

**Scope, corrected accordingly:** this phase does not reclassify regime.
It adds only the fields the 10X spec's own §4 asks for that no existing
engine tracks — history, age, stability, confidence, and a thin macro
cross-check — reading `CRegimeEngine`'s existing classification rather
than duplicating it.

---

## FILES CREATED

- `MQL5/Include/AutopsyX/RegimeIntelligenceEngine.mqh` —
  `CRegimeIntelligenceEngine`, `struct SAxRegimeIntelligence`.
- `docs/PHASE3A_REGIME_INTELLIGENCE_REPORT.md` (this file).

## FILES MODIFIED

`docs/AUDIT_10X_MARKET_INTELLIGENCE.md` — added the correction above.
`Regime.mqh` and `MacroRegime.mqh` themselves are **unmodified** — both
are read-only inputs to the new class, including `Regime.mqh` despite it
being live/wired, per the "preserve existing behavior" instruction.

## INTERFACES CREATED

```
struct SAxRegimeIntelligence { ... }   // see file for full field list

class CRegimeIntelligenceEngine
{
  void Configure(int historyCapacity);
  bool Sample(string symbol, ENUM_TIMEFRAMES regimeTimeframe,
              const CRegimeEngine&, const CMacroRegimeEngine&,
              string macroSymbol, SAxRegimeIntelligence &out);
}
```

## FUNCTIONS CREATED

Constructor, `Configure()`, `Sample()`, private `ComputeConfidence()`.

## DEPENDENCIES

Reads `CRegimeEngine` (live/wired, unmodified) and `CMacroRegimeEngine`
(dormant, unmodified). No new dependency outside
`MQL5/Include/AutopsyX/`. Never calls `CTrade`, never touches order
state, not `#include`d by the live `.mq5`.

## WHAT IS GENUINELY NEW VS. REUSED

Reused, unchanged: `CRegimeEngine::Regime()/VolRatio()/Slope()/R2()`,
`CMacroRegimeEngine::Bias()`. Genuinely new: regime-change history
tracking (previous/changed/age), a stability score over a bounded recent
window, a confidence heuristic grounded in `Classify()`'s own exact
thresholds, and a same-bar macro-agreement check. Explicitly **not**
built: `REGIME_TRANSITION_PROBABILITY` (the future State Transition
Engine's own job — kept for a later phase per the confirmed
architectural decision, not yet authorized) and a numeric "regime change
magnitude" (`ENUM_AX_REGIME`'s 9 states are categorical, not an ordered
scale, and no consumer needs a fabricated distance yet).

## TESTS PASSED

- Balance check: new file — OK. Full repo re-check: 58/58 `.mqh`/`.mq5`
  files — OK, zero mismatches.
- Code review, three passes (high, then medium verify, then a final
  balance/regression check): first pass found 1 real issue (below), fixed
  and verified; second pass found 1 comment-accuracy nit, fixed; third
  pass clean.
- Python regression suite: 27 passed (unaffected by this file, run as a
  regression check).

## TESTS FAILED / BUGS CAUGHT BEFORE COMMIT

1. **Confidence formula scored the wrong axis for `STRONG_TREND`.**
   `Classify()`'s actual deciding condition between `STRONG_TREND` and
   plain `TREND` is `volRatio>=1.15`, given `r2>=0.70` is already
   guaranteed true just to reach that branch. The first draft scored
   only the `r2` margin, which could report ~97% confidence for a
   reading one tick of `volRatio` from flipping to `TREND`, and ~3%
   confidence for the most unambiguous `STRONG_TREND` reading possible.
   Fixed: now takes the weaker of the `r2` margin and the `volRatio`
   margin, matching the same "weakest leg" logic already used for
   `CHAOTIC`.
2. **(Minor, comment-only) inaccurate description of when `TREND` is
   reached.** Fixed for clarity; no functional effect, since the
   confidence formula only ever reads `r2` for that branch.

## KNOWN LIMITATIONS

- **COMPILATION NOT VERIFIED.** No MQL5 compiler in this environment,
  same as every prior phase.
- **`regimeConfidence` is an engineering-design heuristic, not a
  statistically fitted probability** — explicitly labeled as such in the
  file header, matching this codebase's existing precedent (e.g.
  `AlphaEngine`'s `RegimeAlignmentScore`).
- **`BREAKOUT` confidence is a fixed tier (60.0), not a computed
  margin** — `CRegimeEngine::DetectBreakout()`'s own internal
  range-expansion ratio isn't exposed by any public accessor, and
  recomputing it here would duplicate that private method's logic
  against this codebase's "deliberately thin" convention. A future,
  separately-reviewed change to `Regime.mqh` could expose that ratio as
  a new read-only accessor (pure addition, no change to existing
  behavior) if this is ever worth tightening — not done here to avoid
  touching a live file this phase.
- **Macro agreement is a same-bar directional check, not the future
  Causality Engine.** No lead-lag, no rolling/lagged correlation, no
  information decay — that is a separate, later, unbuilt phase (§7).
  Documented explicitly in the file header to prevent this being
  mistaken for that engine's methodology.

## ABLATION TESTING — not performed, same reason as Phase 2

No caller exists yet. Nothing to ablate against. Becomes meaningful once
a later phase (Master Decision Engine or an intermediate consumer)
actually reads `SAxRegimeIntelligence`.

## COMPARISON AGAINST EXISTING BASELINE

The baseline is `CRegimeEngine::Regime()`'s own 9-state output, used
unmodified. This phase adds fields around it; it does not compete with
or replace it. Every new field was checked against `Regime.mqh`'s actual
source (not assumed) before being written.

## REMAINING WORK

Per the confirmed phase ordering, next is **Phase 3b: Volatility ×
Seriality** — adding return autocorrelation, serial correlation, and
variance-ratio measurement (none of which exist anywhere in this
codebase today) on top of `CVolatilityEngine`'s existing 5-state
`ENUM_AX_VOLATILITY_STATE` (also previously under-audited for the same
regex reason — it already covers `NORMAL`/`LOW`/`HIGH`/`EXTREME`/`SHOCK`,
so this too is an extension, not a new taxonomy). Not started as part of
this phase — waiting for explicit sign-off before proceeding, per "wait
for verification before advancing."
