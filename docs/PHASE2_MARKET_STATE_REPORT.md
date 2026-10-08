# Phase 2 Report — Data Integrity + Market State

**Applies to:** `MQL5/Include/AutopsyX/MarketStateEngine.mqh` (new, 312 lines).
**Scope decisions confirmed before this phase started** (recorded here so
this report is self-contained, full detail in
`docs/AUDIT_10X_MARKET_INTELLIGENCE.md`):
1. Market Memory, State Transition, Model Health, Self-Falsification, and
   Execution Alpha are kept for future phases. Not built yet — Phase 2 is
   Data Integrity + Market State only, per the request's own phase order.
2. Leverage Path Engine and all QQQ/TQQQ/NDX specialization are dropped
   from this project. See "Explicitly out of scope" below.
3. Existing Flipdemon Extreme / ICT logic is unmodified. Nothing in this
   phase touches a wired/live file.

---

## FILES CREATED

- `MQL5/Include/AutopsyX/MarketStateEngine.mqh` — `CMarketStateEngine`,
  `struct SAxMarketStateSnapshot`.
- `docs/PHASE2_MARKET_STATE_REPORT.md` (this file).

## FILES MODIFIED

None. No existing file was changed for this phase.

## DATA INTEGRITY — no new file, by design

Per the Phase 1 audit's own finding: `DataIntegrity.mqh`
(`CDataIntegrityEngine`) already implements this request's §26
requirement almost exactly (`Check()` is a fail-closed VALUE/TIMESTAMP/
FRESHNESS/VALIDITY gate with reasoned rejection for impossible prices,
stale quotes, a stuck feed, and abnormal spread). Building a second,
parallel `AutopsyDataIntegrityEngine.mqh` would be the literal duplicate
the request's own audit rules forbid. Instead, `CMarketStateEngine::
Sample()` takes `CDataIntegrityEngine::Check()`'s own bool+reason result
as an input parameter and threads it into `SAxMarketStateSnapshot.
dataComplete`/`incompleteReason` — matching the master pipeline's own
stated order (data integrity gates everything downstream) without
recomputing or duplicating that engine's logic. No wiring of
`DataIntegrity.mqh` into the live EA happened as part of this — it
remains dormant, same as before this phase.

## INTERFACES CREATED

```
struct SAxMarketStateSnapshot { ... }   // see file for full field list

class CMarketStateEngine
{
  void Configure(int capacity, ENUM_TIMEFRAMES barTimeframe);
  bool Sample(string symbol, datetime now, double point,
              bool dataIntegrityOk, string dataIntegrityReason,
              const CMomentumEngine&, const CMicrostructureEngine&,
              const CLiquidityEngine&, const CStructureEngine&,
              const CRegimeEngine&, const CVWAPEngine&,
              const COrderFlowEngine&, SAxMarketStateSnapshot &out);
  int  Count();
  bool GetSample(int back, SAxMarketStateSnapshot &out);
}
```

## FUNCTIONS CREATED

`CMarketStateEngine`: constructor, `Configure()`, `Sample()`, `Count()`,
`GetSample()`, private `RingIndex()`.

## DEPENDENCIES

Reads from (all already-wired-live except `StructureEngine`, which is
dormant but self-contained and safe to read): `CMomentumEngine`,
`CMicrostructureEngine`, `CLiquidityEngine`, `CStructureEngine`,
`CRegimeEngine`, `CVWAPEngine`, `COrderFlowEngine`. No new dependency on
any file outside `MQL5/Include/AutopsyX/`. Does not call `CTrade`, does
not touch order state, is not `#include`d by the live `.mq5` file or any
file that is.

## WHAT IS GENUINELY NEW VS. REUSED

Deliberately thin, per this codebase's established convention: every
STRUCTURE/MOMENTUM/LIQUIDITY/VOLUME/MICROSTRUCTURE/VWAP-trend field is a
direct read of an already-computed accessor, nothing recomputed. Two
things are genuinely new in this file: (1) the raw OHLC/return/gap/range
read (no existing engine exposes plain bar OHLC), and (2) a VWAP-side
transition detector (`vwapTransition`: `VWAP_RECLAIM`/`VWAP_REJECTION`/
`NONE`), which is this engine's own state to own, not a duplicate of
`CVWAPEngine`'s job.

## TESTS PASSED

- **Balance check** (brace/paren/bracket, this codebase's only available
  static structural check): `MarketStateEngine.mqh` — OK. Full-repo
  re-check after adding this file: all 57 `.mqh`/`.mq5` files in `MQL5/`
  — OK, zero mismatches.
- **Code review, medium then high effort, two passes**: first pass found
  3 real issues (see below), all fixed; verification pass confirmed the
  fixes and found one additional low-confidence edge case, also fixed.
  Final pass: no outstanding findings.
- **Python regression suite** (unaffected by this file, run anyway as a
  regression check): `python -m pytest python/tests/` — 27 passed,
  unchanged from before this phase.

## TESTS FAILED / BUGS CAUGHT BEFORE COMMIT

Code review caught 4 real issues in the first draft, all fixed before
this report was written:

1. **Would not have compiled.** Called `CVWAPEngine::GetRollingVwap()`/
   `GetSessionAnchoredVwap()` directly — both are private to that class;
   only `GetVWAP()` (which internally dispatches on the engine's own
   configured mode) and `Mode()` are public. Fixed by switching to
   `GetVWAP()`/`Mode()` and collapsing the two intended fields
   (`rollingVwap`/`sessionVwap`) into one (`vwapValue`) plus the mode
   enum, since only one mode's value is ever actually obtainable from
   outside that class.
2. **Unit mismatch that would have defeated VWAP's own anti-flip-flop
   guard.** `CRegimeEngine::CurrentAtr()` returns a price-space ATR, not
   points (confirmed against `Regime.mqh`'s own `m_currentAtr=atrBuf[0]`
   and the live EA's own point-converting call sites). The draft stored
   it as points directly, then multiplied by point again when calling
   `ClassifyVWAPTrend()`, which expects the raw price-space value —
   collapsing that method's deadband to roughly zero. Fixed: `atrPts` is
   now genuinely `CurrentAtr()/point`, and the raw `CurrentAtr()` value
   (undivided) is passed to `ClassifyVWAPTrend()`, matching every
   existing call site in this codebase.
3. **Unused parameter contradicting the file's own header.** The
   `micro` (`CMicrostructureEngine`) parameter was threaded through the
   full method signature and `#include`d but never read from, despite
   the header claiming this engine reads microstructure state. Fixed by
   adding a genuine MICROSTRUCTURE field group (`tickImbalance`,
   `avgSpreadPts`, `currentSpreadPts`, `spreadExpanding`,
   `spreadCompressing`, `microVolatilityExpanding`), all reused
   accessors, nothing recomputed.
4. **(Verification-pass finding, lower confidence) Stale transition
   state across a data gap.** The VWAP-side tracker didn't clear its
   remembered side when `GetVWAP()` was temporarily unavailable, so a
   multi-bar data gap could make the next valid reading report a
   spurious reclaim/rejection based on pre-gap state. Fixed: the tracked
   side is now cleared (not left stale) whenever `vwapValue<=0`.

No "COMPILES PERFECTLY" claim is made anywhere in this file or this
report — see Verification status below.

## KNOWN LIMITATIONS

- **COMPILATION NOT VERIFIED.** No MetaEditor/MQL5 compiler is available
  in this build environment (unchanged from every prior phase — see
  `docs/VERIFICATION_STATUS.md`). Balance-check + code-review is the only
  verification performed. Item #1 above is a concrete reminder that this
  substitute method is not equivalent to an actual compile — it still
  caught the bug, but only because a reviewer traced the exact class
  definitions by hand, not because a compiler enforced it.
- **Multi-window momentum, relative volume/volume percentile, and a
  discrete liquidity-sweep-event flag are NOT implemented** — none of
  those exist anywhere in this codebase's existing engines to reuse, and
  building them would mean extending `CMomentumEngine`/adding new
  volume-distribution tracking, out of scope for a "deliberately thin"
  state-vector builder. Documented in the file's own header as honest
  gaps, not fabricated.
- **Per-field availability is not independently tracked.** `dataComplete`
  is a single, whole-snapshot flag sourced from the caller's
  `CDataIntegrityEngine::Check()` result. If an individual upstream
  engine (e.g. `CStructureEngine` with zero swings yet) has insufficient
  history, its own fields degrade to their natural empty/zero state
  (e.g. `hasLastSwing=false`), but this is not separately surfaced as a
  per-field quality score. Acceptable for "smallest testable version";
  a richer per-field quality model would be a legitimate future
  refinement, not built here to avoid speculative infrastructure.

## ABLATION TESTING — not performed, and here is why

The request's own instruction is "perform ablation testing before
declaring the module useful." Ablation testing means running the full
system WITH a module versus WITHOUT it and measuring the outcome
difference. This file has **no caller anywhere** — it is not `#include`d
by the live `.mq5`, not read by any other engine, and produces no trading
decision today. There is nothing to ablate: comparing "the live EA" to
"the live EA minus a module it doesn't use" is not a meaningful test, and
running one would either be a no-op (identical results, since the module
affects nothing) or would require inventing a synthetic wiring just to
produce a comparison — which is exactly the kind of speculative
infrastructure this phase was told not to build. Ablation testing becomes
meaningful once (a) a later phase's Master Decision Engine actually reads
this snapshot, and (b) there is a backtest harness capable of running the
live EA with and without that read. Recorded here as a real limitation,
not silently skipped.

## COMPARISON AGAINST EXISTING BASELINE

There is no prior "Market State Engine" to compare against — this is new
capability, not a replacement for existing logic (per the confirmed
architectural decision to augment, not replace). The relevant comparison
is structural: every field this class exposes was checked field-by-field
against the specific existing accessor it reads from (see code-review
pass above), rather than assumed to exist. Where no existing accessor
covers a requested field, that gap is stated in the file's own header
instead of being silently invented.

## EXPLICITLY OUT OF SCOPE (confirmed decision #2)

Leverage Path Engine and QQQ/TQQQ/NDX specialization are not implemented,
not referenced, and introduce no new symbol handling, inputs, or
dependencies anywhere in this codebase. If ever pursued, this should be a
**separate project** (a distinct EA or a distinct include tree), not a
module bolted onto Flipdemon Extreme, since it requires a different
instrument class, a different data-feed relationship (most retail MT5
brokers don't list QQQ/TQQQ at all), and an entirely untested leverage/
daily-reset return-path model that has nothing to do with XAUUSD/FX. This
paragraph is the entire scope of that future-project note — no design
work for it was done, per the instruction not to generate speculative
infrastructure.

## REMAINING WORK

Per the request's own phase order, next is **Phase 3: Regime +
Volatility/Seriality** — per the audit, this is mostly an *extension* of
`Regime.mqh`/`MacroRegime.mqh`/`VolatilityEngine.mqh` (toward the R1-R8
taxonomy, REGIME_CONFIDENCE/STABILITY/AGE/TRANSITION_PROBABILITY, and
serial-correlation/variance-ratio measurement), not new files, matching
the audit's own "files to modify" list. Not started as part of this
phase — waiting for explicit sign-off to proceed, per the request's own
"wait for verification before moving to the next phase" instruction.
