# Phase 4A Report — Information Transmission / Lead-Lag Intelligence Engine

**Authorization:** "AUTOPSY X FLIPDEMON EXTREME — Phase 4A: Information
Transmission / Lead-Lag Intelligence Engine," confirming Phase 3 (commit
`624cce9`) and authorizing 4A only. 4B (Shock DNA) explicitly not started.

---

## 1. Files created

- `MQL5/Include/AutopsyX/InformationTransmissionEngine.mqh` (521 lines) —
  `CInformationTransmissionEngine`, `struct SAxInformationTransmissionSnapshot`,
  `struct SAxLagResult`, `enum ENUM_AX_TRANSMISSION_STATE`.
- `python/autopsy_research/lead_lag.py` (455 lines) — the executable
  reference implementation this MQL5 file mirrors. Same relationship as
  `trade_direction.py` has to `TickDirectionEngine.mqh`.
- `python/tests/test_lead_lag.py` (321 lines) — the 12 deterministic
  synthetic tests this phase's own authorization requires, plus 2
  additional numerical-safety/structural-proof tests.
- `docs/PHASE4A_INFORMATION_TRANSMISSION_REPORT.md` (this file).

## 2. Files modified

**None.** `git status --short` shows only the 4 files above as untracked;
nothing existing changed.

## 3. Existing files intentionally untouched

`Regime.mqh` (live), `RegimeClassifierEngine.mqh` (Phase 3, its
`ENUM_AX_REGIME_CLASS` is reused, not modified), `MacroRegime.mqh`,
`VolatilityEngine.mqh`, `RiskEngine.mqh`, `EmergencyControls.mqh`,
`EntryEngine.mqh`, `ExecutionEngine.mqh`, `ExitEngine.mqh`,
`TradeAutopsy.mqh`, `Statistics.mqh`, `StructureEngine.mqh`,
`Liquidity.mqh`, `VWAPEngine.mqh`, `AutopsyX_FlipDemon_Extreme.mq5` — all
confirmed unmodified (`git status`) and unreferenced by the new engine
(grep, zero matches for `CRiskEngine`, `CExecutionEngine`, `CExitEngine`,
`CEntryEngine`, `CTradeAutopsy`, `CVWAPEngine`, `CStructureEngine`,
`CLiquidityEngine`, `CTrade`, `CEmergencyControls` inside the new file).

## 4. Architecture implemented

**Repository audit finding (done before writing code):** no existing
engine performs lagged cross-asset correlation. `CMacroRegimeEngine`
(`MacroRegime.mqh`) reads one configurable cross-asset symbol for a
zero-lag directional bias only — no lag scan, no stability check, no
regime bucketing. `python/autopsy_research/correlation.py` computes
zero-lag Pearson correlation across return streams for a strategy-
crowding purpose — its base statistic (Pearson correlation) is reused,
but nothing else (no lag scan, no divergence detection, no confidence
scoring) is duplicated. `var_model.py` is a single-instrument VAR (quote
change vs. net order flow), a different scope from cross-symbol lead-lag.
No shared statistics library exists in `MQL5/Include/AutopsyX/` beyond
what's private to `Regime.mqh` (linear regression) and `DataIntegrity.mqh`
(rolling z-score) — this file's `PearsonCorr()`/`NormalInverseCdf()` are
new, self-contained, and confirmed non-duplicative.

`CInformationTransmissionEngine` is a new, standalone class. It reuses
`RegimeClassifierEngine.mqh`'s existing `ENUM_AX_REGIME_CLASS` (Phase 3)
for regime-dependence bucketing rather than inventing a competing
taxonomy — the only cross-file dependency this engine has. It is not
`#include`d by the live `.mq5` file (confirmed by grep) and calls no
`CTrade` method.

## 5. Measurements implemented

Per the authorization's Measurement Framework section, all six:

- **A. Directional Association** — sign of Pearson correlation at each
  scanned lag; supports both positive and inverse relationships.
- **B. Lag** — bounded scan over `[0, maxLag]` (configurable, default
  10), reporting the strongest-association lag, its strength, direction,
  and sample count. Never an unbounded lag range.
- **C. Response Magnitude** — mean receiver return in the
  historically-implied direction following a leader observation, using
  log returns (scale-invariant across instruments), not raw price
  differences.
- **D. Stability** — older-half vs. recent-half correlation comparison
  on the same paired observations; a relationship that flips sign is
  never reported as stable.
- **E. Regime Dependence** — correlation recomputed within each
  `ENUM_AX_REGIME_CLASS` bucket the caller has tagged each observation
  with (Phase 3's own classification, reused unmodified); a bucket below
  `minRegimeSampleSize` is excluded, not fabricated.
- **F. Divergence** — the transmission-state waterfall (below) exists
  specifically to detect relationship breakdown, sign inversion, and
  strength collapse, not just confirmation.

## 6. Statistical methodology

Pearson correlation at each scanned lag (`PearsonCorr`, zero-variance →
0.0, never NaN). Confidence is the **gated minimum** of independent
evidence factors (sample-size adequacy, association strength, stability),
never a blind average — matching this codebase's existing
`TradePermissionMatrix.mqh` "hard gates, not averages" convention —
zeroed on `INSUFFICIENT_DATA`/`INACTIVE`, and halved under
`DIVERGING`/`WEAKENING`/`INVERTED`.

**Multiple-comparisons correction (a real finding, not a stylistic
choice):** scanning `maxLag+1` lags and keeping the strongest is a "best
of N" selection. An empirical check in the Python reference — 100
independent seeded pairs of genuinely unrelated series, n=400, max_lag=10
— found a **22% false-positive rate** at a flat `|r| ≥ 0.15` threshold
and **0%** at 0.25. The engine therefore uses `effectiveMinAssociation =
max(minAssociation, SignificanceFloor(n, numLagsScanned))`, where
`SignificanceFloor` is a Bonferroni-corrected statistical noise floor
(`NormalInverseCdf` — Acklam's well-established rational approximation to
the standard normal inverse CDF, since MQL5 has no built-in statistical
distribution functions) and `minAssociation`'s default was raised from
0.15 to 0.25 based on that same empirical result. A follow-up check
across 300 *different*, previously-unused seeds found a **0/300**
false-active rate under the corrected design — confirming the fix
generalizes rather than being tuned to the two seeds that originally
exposed the problem.

**Terminology discipline:** neither file uses "causal"/"causality"
anywhere. All language is "information transmission," "lead-lag,"
"predictive association," matching the authorization's explicit
requirement.

## 7. Timestamp/alignment convention

Documented in both files' own headers, stated once here: leader and
receiver are sampled at the **same reference bar-close event**, using the
leader symbol's own closed-bar time (`iTime(leaderSymbol, barTimeframe,
1)`) as the reference clock. At that event, both symbols' own `CopyClose`
reads are attempted independently; if either fails, the **whole pair is
skipped**, never fabricated from one side. Lag is a plain array-index
offset into this shared sequence, not a raw timestamp computation. This
is an explicit, documented simplification — true differing-trading-hours
alignment (an instrument on a different session calendar) is **not**
implemented; see Limitations.

## 8. Look-ahead protections

For lag ≥ 0, the receiver observation at ring-buffer index `i` is only
ever compared against the leader observation at index `i - lag` — at or
before `i`, never after. `lag == 0` compares two already-closed bars
(legitimate, not look-ahead). No code path reads a ring-buffer slot
beyond what has actually been pushed (verified in code review, both MQL5
passes). Both symbols require `SymbolSelect` before reading (a mistake
already caught and fixed once before, in `ORBEngine.mqh`'s own
cross-asset confirmation method during Phase 3 — applied proactively
here from the start rather than rediscovered).

**Executable proof, not just a claim:** `test_12_lookahead_trap`
constructs a receiver series that would correlate perfectly with the
leader if future information leaked (`receiver[i] == leader[i+1]`) and
asserts the engine reports `INACTIVE` with no lag showing a spurious
strong read. It passes. `test_lag_scan_never_reads_future_index` is a
direct structural proof independent of any synthetic data.

## 9. Missing/stale data behaviour

- **Missing symbol / unavailable history:** `SymbolSelect` + `CopyClose`
  failure on either symbol → whole pair skipped, `Sample()` returns
  `false` (no-op, retried next tick), matching the same fix pattern
  already applied in Phase 3's `VolatilitySerialityEngine.mqh`.
- **Insufficient history:** `sampleCount < minSampleSize` →
  `AX_TS_INSUFFICIENT_DATA`, confidence 0, `bestLag = -1`.
- **Stale/bad current-tick data:** the caller's own `dataIntegrityOk`
  flag gates whether a bar's return is pushed into the rolling window at
  all — a bad-data bar never contaminates history (same fix pattern as
  Phase 3).
- **Zero/invalid prices:** every close is checked `> 0` before use.
- **Division by zero:** `PearsonCorr` returns `0.0` (not NaN/exception)
  on zero variance on either side. `SignificanceFloor` guards `n < 4`.
- **NaN-like values:** never produced — every division site is guarded.

Executable proof: `test_9_missing_data` (too few observations →
`INSUFFICIENT_DATA`, no fabrication), `test_10_stale_data` (only the
single most-recent stale pair dropped, earlier history intact),
`test_pearson_corr_zero_variance_returns_zero_not_nan`.

## 10. Unit tests and exact results

All 12 required tests, implemented literally against the naming/intent
given in the authorization, plus 2 extra. **Run for real** (not claimed):

```
$ python3 -m pytest python/tests/test_lead_lag.py -v
test_1_perfect_positive_lead PASSED
test_2_perfect_inverse_lead PASSED
test_3_no_relationship PASSED
test_4_zero_lag_relationship PASSED
test_5_known_lag_shift PASSED
test_6_regime_dependent_relationship PASSED
test_7_relationship_breakdown PASSED
test_8_relationship_inversion PASSED
test_9_missing_data PASSED
test_10_stale_data PASSED
test_11_timestamp_misalignment PASSED
test_12_lookahead_trap PASSED
test_pearson_corr_zero_variance_returns_zero_not_nan PASSED
test_lag_scan_never_reads_future_index PASSED
============================== 14 passed in 0.84s ==============================
```

These tests exercise the **Python reference implementation**
(`lead_lag.py`), not the MQL5 file directly — MQL5 cannot be executed in
this environment (see item 14). The MQL5 port was then checked line-by-
line against this same tested algorithm in code review (item 15) rather
than independently run.

## 11. Existing regression results

```
$ python3 -m pytest python/tests/ -q
41 passed in 3.10s   (27 pre-existing + 14 new, zero failures, zero regressions)
```

MQL5 side: `git status --short` confirms zero existing files modified;
grep confirms zero references to the new engine anywhere in
`AutopsyX_FlipDemon_Extreme.mq5`, and zero references from the new engine
into entry/risk/execution/journal/ICT/VWAP subsystems.

## 12. Balance-check result

```
$ find MQL5 -name "*.mqh" -o -name "*.mq5" | wc -l
61
$ python3 balance_check.py <all 61 files>
(0 mismatches - every file reports "OK (balanced)")
```

## 13. Python test result

`41 passed in 3.10s` — see item 11 (full output shown there).

## 14. MQL5 compilation status

**MQL5 compilation not verified because no actual MQL5 compiler was
available.** No MetaEditor, no MT5 terminal exists in this build
environment — unchanged from every prior phase (`docs/VERIFICATION_STATUS.md`).
Static inspection (balance-check + code review) is not a substitute for
compilation and is not reported as one.

## 15. Review findings and fixes

Six review passes were performed on `lead_lag.py`/its tests (run for
real, so failures were genuine test output, not inspection) and on the
MQL5 port (static, since MQL5 can't run here):

**Pass 1 (architecture/integration safety):** confirmed zero coupling to
entry/risk/execution/journal/ICT/VWAP; confirmed `RegimeClassifierEngine.mqh`
reuse rather than a competing taxonomy; confirmed no QQQ/TQQQ/NDX/NQ
anywhere (grep, zero matches, both MQL5 and Python files).

**Pass 2 (statistical correctness)** — 3 real bugs, found by tests
actually failing, not by inspection:
1. The transmission-state waterfall gated `INACTIVE` on the full-window
   correlation *before* checking older-vs-recent divergence. A textbook
   inversion (strong positive half, strong negative half of similar
   magnitude) cancels the full-window correlation toward zero *by
   construction*, so this order misclassified the exact scenario
   `INVERTED` exists to catch as `INACTIVE` instead
   (`test_8_relationship_inversion` failing surfaced this). Fixed by
   reordering the waterfall so older-vs-recent checks run first.
2. The 22% false-positive rate from best-of-N-lags selection (item 6) —
   found because `test_3_no_relationship` and `test_12_lookahead_trap`
   both failed against the original flat `0.15` threshold. Fixed with
   the Bonferroni-corrected significance floor.
3. A shared module-level RNG in the test file made `test_3`'s outcome
   depend on test execution *order* (passed in isolation, failed after
   two prior tests had consumed draws from the same generator) — a test-
   hygiene bug, not an engine bug. Fixed: every test now uses its own
   independently-seeded generator.

**Pass 3 (timestamp alignment and look-ahead bias):** the original
`align_returns` conflated "staleness" (a live, most-recent-tick concept)
with "historical age" (every past bar is old relative to `now` *by
definition* — that isn't invalidity). This made `test_10_stale_data` and
`test_11_timestamp_misalignment` both fail — every historical bar failed
its own staleness check purely for being historical. Fixed by splitting
into two distinct checks: staleness applies **only to the single most
recent pair** (mirroring `CDataIntegrityEngine`'s own current-tick-only
convention), and a separate, per-pair misalignment tolerance was added.

**Pass 4 (missing/stale data and failure safety):** confirmed via items
9-10 above; no additional findings beyond what pass 3 already fixed.

**Pass 5 (computational efficiency):** bar-level only (`Sample()` no-ops
except on a new leader bar); bounded ring buffer (default capacity 500);
bounded lag range (configurable, default `maxLag=10`); regime-bucket loop
is `O(9 × m)` — the `9` is the fixed `ENUM_AX_REGIME_CLASS` count, not
data-size-dependent, confirmed in MQL5 code review, not `O(n²)`.

**Pass 6 (MQL5 correctness and compile risks)** — 2 rounds, MQL5 static
review only:
1. First pass: regime "strongest bucket" tie-break used
   `!hasStrongest || |corr| > |strongestCorr|`, which unconditionally
   promotes whichever sufficient regime bucket is scanned *first*, even
   at exactly `corr == 0.0` — diverging from the Python reference's
   strict `abs(corr) > abs(strongest_regime_corr)` (which starts at 0.0
   and requires a genuinely nonzero correlation before ever promoting a
   bucket). Fixed by removing the `!hasStrongest ||` short-circuit.
2. Verify pass: fix confirmed correct against the Python reference;
   `RingIndex` modulo math, `ArrayResize` size/indexing consistency,
   `SAxLagResult` struct-array full-initialization-before-read, and every
   return path's full field coverage on `SAxInformationTransmissionSnapshot`
   all checked clean, no further findings.

**Every genuine defect found was fixed before this report was written.**

## 16. Ablation status and why

**Ablation not applicable at this phase because the engine is
observational and has no live decision caller.** Confirmed by grep: zero
references to `CInformationTransmissionEngine` anywhere in
`AutopsyX_FlipDemon_Extreme.mq5` or any file that is itself wired live.
There is no trading decision to compare with-vs-without. Manufacturing a
synthetic wiring solely to produce an ablation number would be exactly
the fabricated-performance-number this phase explicitly forbids. No
performance numbers are invented anywhere in this report.

## 17. Known limitations

- **Alignment is index-based on a shared reference clock, not a
  general-purpose multi-session timestamp aligner.** True differing-
  trading-hours alignment (an instrument closing on a different session
  calendar than the leader) is not implemented — stated in both files'
  own headers, not discovered later.
- **Regime-dependence bucketing is only as good as the caller's own
  Phase 3 classification for that bar** — this engine never recomputes
  or validates it, by design (reuse, not duplication).
- **`responseMagnitude` and `associationStrength` for `DIVERGING`/
  `WEAKENING` describe the *historical* (older-half) reading, not the
  current one** — this is a deliberate, documented choice ("what it used
  to be" is the honest content of a fading-relationship state), not an
  oversight, but a caller must read the `state` field to know which
  regime of meaning `associationStrength` carries.
- **`SignificanceFloor`'s Bonferroni correction assumes approximately
  independent lag comparisons.** Adjacent lags on the same two series
  share most of their data and are not fully independent, so this is a
  conservative approximation, not an exact multiple-comparisons
  correction for a genuinely dependent lag-scan — a known simplification
  in this class of method, not unique to this implementation, and not
  something a from-scratch exact correction was attempted for (would
  turn a "clean statistical transmission layer" into a research project,
  against this phase's own instruction).
- **The `minRegimeSampleSize` default (15) and `weakeningRatio` default
  (0.5) are engineering-design choices**, not independently validated
  against real market data (none is available in this build
  environment) — consistent with every other engineering-design
  threshold already documented throughout this codebase.
- **MQL5 compilation not verified** (item 14) — the MQL5 file was
  checked by hand against the tested Python algorithm, not independently
  executed.

## 18. Whether the engine is wired into live trading

**No.** Confirmed by grep: zero references to
`CInformationTransmissionEngine`, `InformationTransmissionEngine.mqh`, or
`SAxInformationTransmissionSnapshot` anywhere in
`AutopsyX_FlipDemon_Extreme.mq5`. Not `#include`d by the live file or by
anything the live file includes. Calls no `CTrade` method anywhere in its
own source. Not connected to entry permission, risk, or execution in any
way.

## 19. Confirmation: no QQQ/TQQQ/NDX/NQ logic introduced

Confirmed by grep (case-insensitive) across `InformationTransmissionEngine.mqh`,
`lead_lag.py`, and `test_lead_lag.py` for `QQQ`, `TQQQ`, `NDX`, `NQ` —
**zero matches** in all three files. The engine is instrument-agnostic
(takes `leaderSymbol`/`receiverSymbol` as plain configurable strings) and
was designed, tested, and documented exclusively in terms of XAUUSD and
major-FX-appropriate examples (DXY, yields, correlated FX pairs) per the
authorization's own scope section.

## 20. Commit hash

`8557cb9` (pushed to `origin/claude/autopsy-flipdemon-extreme-l4ei3d`).
