# Phase 6 — Verification, Integration Readiness & Production-Gate Audit

**Commit at time of audit:** 833ade5
**Scope:** verification only. No architecture rewrite, no new engines, no
ML, no parameter optimization, no wiring of any dormant layer into live
execution. This report answers one question: *is AUTOPSY X technically
ready for controlled integration testing, or are there still verification
blockers?* It is not a profitability judgment.

---

## 1. Executive status

**Layer 1 (live) is architecturally sound and internally consistent** —
single risk authority, single execution authority, single sizing chain,
every entry funneled through one gate sequence, every invariant this audit
could trace held. **It has never been compiled, never run in the Strategy
Tester, and never forward- or live-tested.** Layers 2, 3, and two
previously-undocumented dormant modules (§3) remain fully isolated from
live execution — verified freshly, not assumed. Phase 5's real-data
research conclusion (0/54 hypotheses survived correction) is accurately
reflected in its own documentation. No hard-stop condition from §3 of the
authorization was found. Final gate: **ARCHITECTURALLY VERIFIED** (§21).

## 2. Repository audit — hard-stop conditions (authorization §3)

Every condition below was actively searched for, not assumed absent.

| Condition | Result | Evidence |
|---|---|---|
| Hidden live trading calls in dormant modules | **NONE FOUND** | Regex scan (comment-stripped) of all 36 dormant `.mqh` files for `OrderSend`/`.Buy(`/`.Sell(`/`.PositionOpen(`/`.PositionClose(`/`.PositionModify(`/`.BuyStop(`/`.SellStop(` — zero real matches. All textual `CTrade`-adjacent hits were either explicit "never calls CTrade" comments or class names (`CTradeAutopsy`, `CTradePermissionMatrix`, `CTradeLifecycle`, `CTradeReconciler`) sharing a naming prefix, not calls. Automated as `test_every_dormant_module_has_zero_execution_authority` (`python/tests/test_architecture_invariants.py`). |
| Undocumented OrderSend equivalents | **NONE FOUND** | Same scan covers `OrderSendAsync`, `BuyLimit`/`SellLimit` too. |
| Accidental `CTrade` execution in dormant modules | **NONE FOUND** | `test_exactly_one_ctrade_instance_in_the_entire_include_tree` — exactly one `CTrade` member declared repo-wide, inside `CExecutionEngine` (live). |
| Execution references from Phase 2–5 engines | **NONE FOUND** | Covered by the same dormant-module scan; Phase 2–4B engines additionally each carry their own "not #include'd by the live EA" header claim, now independently verified rather than trusted. |
| Hidden dependency, Python → MQL5 | **NONE FOUND** | No `#import`, no `WebRequest`, no socket/pipe/shared-memory/subprocess bridge anywhere in `MQL5/`, `python/`, or `research/`. Automated as `test_no_python_mql5_ipc_bridge`. |
| Hidden dependency, MQL5 → research-only modules | **NONE FOUND** | The live EA's transitive `#include` closure was walked (not just its direct list) and contains none of the 36 dormant modules. Automated as `test_no_dormant_module_reachable_transitively_from_the_live_ea`. |
| Duplicated risk authority | **NONE FOUND** | `m_riskPercent` has exactly one caller-driven write site (`RiskEngine.mqh::Configure()`), clamped `[0.05, 2.0]`. `DynamicPositionSizing.mqh` (dormant) explicitly documents in its own header that it never calls `CalculateLotSize()`. |
| Duplicated position-sizing authority | **NONE FOUND** | `CalculateLotSize()` has exactly one call site in the entire repository: `AutopsyX_FlipDemon_Extreme.mq5:723`. |
| Conflicting regime authorities | **NOT APPLICABLE TO LIVE PATH** | `CRegimeEngine` (live) is the sole regime source Layer 1 reads. `RegimeClassifierEngine.mqh`/`RegimeIntelligenceEngine.mqh` (Layer 3, dormant) are explicitly built as read-only *consumers* of `CRegimeEngine`'s own output, never a second classifier — confirmed in Phase 3's own report and by this audit's dormant-isolation scan. No conflict exists because the dormant layer was never in a position to compete. |
| Conflicting volatility authorities | **NOT APPLICABLE TO LIVE PATH** | Same pattern: `VolatilitySerialityEngine.mqh` (dormant) reads `CVolatilityEngine` (also dormant, Layer 2) as an already-computed input; neither is reachable from live code. |
| Accidental modification of Phase 4A/4B frozen logic | **NOT MODIFIED** | `git log` shows no commits touching `InformationTransmissionEngine.mqh` or `ShockDNAEngine.mqh` since their respective phase closeouts; Phase 6 made zero edits to either file. |
| Future-data references / look-ahead paths | See §8 | Existing prefix-invariance tests reviewed; no new violation found. |
| Stale-data paths that fail open | See §9 | Layer 1's own tick gate fails closed; Layer 2's fuller staleness detection is dormant (not a live-path defect, since it was never claimed to be active). |
| Missing-data paths that produce fabricated values | **NONE FOUND** | Every engine audited in Phases 2–5 returns an explicit unavailable/insufficient-data state rather than a guessed number; re-confirmed for Layer 1's `MarketData::OnTickUpdate()` (§9 below). |
| Silent fallback values that can become trading signals | **NONE FOUND** in the live path | `SignalScorer`/`CRegimeEngine` etc. were not found to substitute a guessed value for missing input anywhere in the live chain. |
| Risk limits that can be bypassed | **NOT FOUND BYPASSABLE** | See §5 (Risk Invariant Audit) — every gate lives inside one function, `PreTradeAllowed()`, with no alternate path to `CTrade` that skips it (traced in §6). |
| Position sizing that can exceed Layer 1 limits | **NOT FOUND** | See §5 — `AxClampD` bounds `[0,1]` on every downstream multiplier, re-verified by `test_adaptive_flip_engine_multiplier_is_bounded_to_unity`. |
| Dormant modules accidentally instantiated by the live EA | **NONE FOUND** | Impossible by construction — MQL5 cannot instantiate a class whose header was never `#include`d, and the transitive-include test proves none of the 36 dormant headers are reachable. |
| External API dependencies in execution-critical code | **NONE FOUND** | Same `#import`/`WebRequest` scan, repo-wide. |
| Test code imported by production MQL5 logic | **NOT APPLICABLE** | No `*test*` file exists anywhere under `MQL5/` at all. |

**No hard-stop condition was found. No architectural changes were made in response to this section**, per the authorization's own instruction to document before fixing.

## 3. Architecture map — a fourth, previously undocumented dormant group

Confirmed by full file-set diffing (`ls MQL5/Include/AutopsyX/*.mqh` minus
the live `#include` set): **36 dormant modules**, not the 33 the existing
docs (`EA_DESCRIPTION.md`) accounted for (28 Layer 2 + 5 Layer 3 files —
Layer 3 is actually 6 files, not 5, since Phase 3 produced two:
`RegimeClassifierEngine.mqh` and `VolatilitySerialityEngine.mqh`, plus
Phase 3a's separate `RegimeIntelligenceEngine.mqh`). The arithmetic:
28 (Layer 2) + 6 (Layer 3) + **2 previously uncatalogued** = 36.

The two uncatalogued modules are complete, independent, paper-sourced
trading strategies that predate this document's own audit trail:

- **`ORBEngine.mqh`** — Opening Range Breakout, from Zarattini & Aziz,
  SSRN 4416622 (2023).
- **`NoiseAreaEngine.mqh`** — intraday noise-area momentum, from
  Zarattini, Aziz & Barbon, SSRN 4824172 (2024/2025).

Both were confirmed, freshly, to contain **zero execution authority**
(same scan as §2) and are **not** `#include`d by the live EA. They are
architecturally isolated exactly like Layers 2 and 3 — the finding here is
purely a **documentation gap**, not a safety gap: two fully-built dormant
strategies existed with no entry in the layer taxonomy a reader of
`EA_DESCRIPTION.md` would rely on. Fixed in this phase (§17) by adding
them to that document under their own heading, since this is a low-risk,
in-scope documentation correction, not a code change.

## 4. Authoritative ownership map

| Concept | Authoritative owner | Secondary readers | Trading authority? |
|---|---|---|---|
| Market Data | `CMarketData` (live) | every live engine; `DataIntegrity.mqh` (dormant, would read it if wired) | No — read-only tick/quote store |
| Data Integrity | **`CDataIntegrityEngine`** (dormant) — Layer 1 has only a minimal inline gate (`MarketData::OnTickUpdate()`, bid/ask<=0 rejection), not a full staleness/spread-z-score/stuck-feed system | none live | No |
| Market Structure | `CStructureEngine` (dormant, BOS/CHoCH/MSS) — Layer 1 has no equivalent; `CRegimeEngine` (live) covers trend/range/breakout classification, a different concept | `CCompositeDirectionEngine` (dormant) | No — signal-only even when active |
| VWAP | `CVWAPEngine` (live) | `CAdaptiveFlipEngine` (alignment bonus, live), `CExitEngine` (mechanical exit, live) | No — informs exit/sizing decisions, never sends orders itself |
| Momentum | `CMomentumEngine` (live, tick-level) | `SignalScore`, `FlipEngine`, `ExitEngine` (all live) | No |
| Liquidity | `CLiquidityEngine` (live) | `SignalScore`, `SniperEngine` (live) | No |
| Volatility | `CRegimeEngine::CurrentAtr()` (live, the only volatility figure Layer 1 actually reads) — `CVolatilityEngine` (dormant, 5-state percentile/acceleration classification) is a separate, richer concept never wired in | `VolatilitySerialityEngine.mqh` (dormant) reads `CVolatilityEngine`, not `CRegimeEngine` | No |
| Regime | `CRegimeEngine` (live, run twice: trading TF + HTF confluence) | `RegimeClassifierEngine.mqh`/`RegimeIntelligenceEngine.mqh` (dormant, both read-only consumers, never reclassify) | No |
| Risk | `CRiskEngine` (live) — sole owner of `m_riskPercent` and every hard circuit breaker | `Dashboard`, `AdaptiveFlipEngine`, `Statistics` (read `RiskPercent()`/`DailyPnL()` etc., never write) | **Yes — the only class with trading-permission authority** |
| Position Size | `CRiskEngine::CalculateLotSize()` (live, sole computation) then `CAdaptiveFlipEngine` (live, scale-down-only multiplier) then order-book impact-cost cap (live, scale-down-only) | `DynamicPositionSizing.mqh` (dormant) — explicitly documents it never touches `CalculateLotSize()` | Indirectly — determines size, never permission |
| Execution | `CExecutionEngine` (live) — sole `CTrade` instance in the repository | none | **Yes — the only class that can reach the broker** |
| Trade Permission | `AxAttemptEntry()` (live, in the `.mq5` file itself) — the single funnel every entry (ENTRY/FLIP/SNIPER) passes through, gating emergency controls then `RiskEngine::PreTradeAllowed()` then session/signal checks | `CTradePermissionMatrix` (dormant, 15-gate composite — never reached) | Yes — this is the actual live gatekeeper |
| Journal | `CTradeAutopsy` (live, 43-column CSV) | `CStatistics`, `Dashboard` (live, read-only); `PerformanceAttribution`/`DrawdownAnalytics`/`ExplainabilityLog` (dormant, all documented as read-only consumers of the same ledger) | No |
| Learning | **NONE** | — | No adaptive-parameter or ML module exists anywhere in this codebase, live or dormant. `AdaptiveFlipEngine` adapts a *multiplier* from live state; it does not learn or fit a parameter from historical data. |

**No duplicate ownership, no competing implementation, and no hidden
override was found for any concept with trading authority.** The two
ambiguous-sounding cases (Volatility, Market Structure) resolve cleanly
once traced: Layer 1 and the dormant layers use genuinely different,
non-conflicting concepts under similar names, not two implementations of
the same one.

## 5. Execution path trace

```
OnInit()
  -> g_md.Init(), g_risk.Configure(), g_entryEngine.Configure(),
     g_emergency.Configure(InpExecutionMode, InpEnableTrading, ...),
     g_exec (CExecutionEngine) constructed with CTrade bound to _Symbol
  -> failure behaviour: INIT_FAILED on any required handle/config failure
     (each engine's own Init()/Configure() return value checked)

OnTick()
  -> g_md.OnTickUpdate() -- MarketData.mqh:79
     input: SymbolInfoTick(); output: bool (false on bid<=0||ask<=0)
     failure behaviour: `if(!g_md.OnTickUpdate()) return;` (.mq5:1071) --
     fails closed, the ENTIRE tick is skipped, no state is advanced
  -> g_regime.Update() / g_momentum.Update() / g_micro.Update() / g_liq.Update()
     (live engines, read from g_md) -- signal-only, no trading authority
  -> g_score = SignalScorer::Compute(...) -- SignalScore.mqh, produces
     0-100 buy/sell score + confidence, signal-only
  -> AxAttemptEntry(dir, score, flipSeq, tag) -- .mq5:648, the SOLE entry
     funnel (called from FLIP/.mq5:1212, SNIPER/.mq5:1299, ENTRY/.mq5:1344)
       1. g_emergency.CanEnterDirection() -- checked FIRST, deliberately
          ahead of risk, so an operator stop is never mistaken for an
          ordinary gate decline (.mq5:651-654)
       2. g_risk.PreTradeAllowed() -- .mq5:661, RiskEngine.mqh:275
          (kill switch, daily/weekly loss, consecutive losses, execution
          failures, position/exposure caps, flip cap, rolling-window trade
          cap, spread ceiling, margin usage/level/free-margin)
       3. g_entryEngine.SessionAllowed() -- .mq5:667
       4. (inside the calling branch) g_entryEngine.PreFlightCheck() --
          .mq5:1316/1353, a SECOND, redundant call into
          riskEngine.PreTradeAllowed() plus TradingPermitted/SignalQuality/
          StopDistance checks -- defense-in-depth, not a bypass (both must
          pass; PreTradeAllowed has no side effects that make double-
          calling unsafe)
       5. g_risk.CalculateLotSize() -- .mq5:723, RiskEngine.mqh:157, the
          SOLE lot-size computation in the repository
       6. g_afe.Evaluate() (if InpUseAdaptiveFlipEngine) -- .mq5:751,
          returns a [0,1]-clamped multiplier; can block the entry outright
          (return false) or scale lots down, never up (.mq5:762-779)
       7. heatmap impact-cost cap (if InpUseImpactCostSizing) -- .mq5:786,
          scale-down-only (`if(maxAffordableLots<lots)`)
       8. g_exec.OpenMarket()/equivalent -- ExecutionEngine.mqh, the SOLE
          CTrade.Buy()/.Sell() call site -- reaches the broker here
     failure behaviour at every step: return(false) from AxAttemptEntry,
     no partial state committed, verbose-logged reason available
  -> on success: g_posState updated, journaled via g_autopsy on close

Position management / exit (every OnTick while a position is open)
  -> CExitEngine checks (momentum-collapse, microstructure-reversal,
     max-hold, spread-abnormal, execution-quality breaker, VWAP mechanical
     exit, breakeven/trailing) -- signal decisions only, still routed
     through g_exec.ClosePosition()/PositionModify() for the actual call

OnTimer()
  -> Dashboard redraw, Statistics recompute (both read-only), daily/weekly
     equity-anchor rollover inside CRiskEngine

Deinit
  -> g_exec destructor releases the CTrade object; no order-in-flight
     state persists outside MT5's own broker-side order book
```

The exact functions through which an order can reach the broker:
**`CExecutionEngine::OpenMarket()`, `::ClosePosition()`,
`::ClosePositionPartial()`, `::ModifyPosition()`,
`::OpenPendingOrder()`, `::DeletePendingOrder()`** — all inside
`ExecutionEngine.mqh`, all wrapping the single `m_trade` (`CTrade`)
instance. No other function in the repository calls a `CTrade` method.

## 6. Risk invariant results

| # | Invariant | Verdict | Traceable path |
|---|---|---|---|
| A | No trade may exceed the configured hard per-trade risk ceiling | **PASS** | `m_riskPercent` clamped `[0.05,2.0]` at its one write site (`RiskEngine.mqh`); `CalculateLotSize()` sole call site; broker-volume re-normalization confirmed applied *after* the exposure clamp too (`docs/RISK_INVARIANT_AUDIT.md`, Finding 1, fixed in `bfd079e`) |
| B | Adaptive logic may only reduce risk | **PASS** | `m_lastRiskMultiplier = AxClampD(baseMult,0.0,1.0)` — the only runtime write; four independent bounding mechanisms traced in `docs/RISK_INVARIANT_AUDIT.md`; automated as `test_adaptive_flip_engine_multiplier_is_bounded_to_unity` |
| C | No module may independently increase account exposure | **PASS** | Every downstream sizing step (AFE, impact-cost cap) is provably scale-down-only (`if(x < lots)` / multiplier `<=1.0`); no reciprocal/divisor form of any multiplier exists anywhere (grepped) |
| D | Daily loss protection cannot be bypassed | **PASS** | `PreTradeAllowed()` checks `DailyLossLimitBreached()` unconditionally, first three lines of the function; single call path to `CTrade` per §5 |
| E | Weekly loss protection cannot be bypassed | **PASS** | Same function, `WeeklyLossLimitBreached()`, same reasoning |
| F | Consecutive-loss lockout cannot be bypassed | **PASS** | Same function, `ConsecutiveLossLimitBreached()` and `ExecutionFailureLimitBreached()` |
| G | Margin protection cannot be bypassed | **PASS** | Same function, `MarginUsageAcceptable()` plus explicit `marginLevel`/`marginFree` checks (`RiskEngine.mqh:296-302`) |
| H | Emergency shutdown cannot be bypassed by another engine | **PASS** | `m_killed` is the FIRST check in `PreTradeAllowed()`; `ActivateKillSwitch()` has exactly 3 call sites (poor-fill threshold, execution-failure threshold, manual button), all live-path only; no dormant module can reach `RiskEngine` at all (§2) |
| I | Dormant intelligence engines cannot authorize an order | **PASS** | §2/§3 — zero execution authority, zero reachability, confirmed by both manual trace and the automated test suite |
| J | Diagnostic engines (Kelly/Ruin, Monte Carlo) cannot authorize an order | **PASS** | Both dormant (unreachable, §2); `KellyRuin.mqh`'s own header states outright: "NEVER let this class's output authorize or size a live trade — this is diagnostics, nothing more" — a claim this audit independently verified rather than took on faith |

All ten invariants trace to a real, verifiable implementation path.
**None were classified PASS on architectural intent alone** — every PASS
above cites a specific file, function, and (where practical) an automated
regression test.

## 7. Dormant-layer isolation

Confirmed, freshly, for Layer 2 (28 modules), Layer 3 (6 modules), and the
newly-catalogued pair (§3) — 36 modules total, zero exceptions:

- Zero `CTrade`/`OrderSend`/execution-callback references (real code, not comments).
- Zero reachability from the live EA's transitive `#include` closure.
- Zero risk-mutation or position-sizing-mutation calls into `CRiskEngine`.

Automated: `python/tests/test_architecture_invariants.py`
(`test_every_dormant_module_has_zero_execution_authority`,
`test_no_dormant_module_reachable_transitively_from_the_live_ea`).

## 8. Python/MQL5 parity

| Component | Verdict | Basis |
|---|---|---|
| Lead-Lag / Information Transmission (Phase 4A) | **EXACT** (post-audit) | `lead_lag.py` and `InformationTransmissionEngine.mqh` carry the identical significance-floor fix, ported line-for-line after the independent adversarial audit found and fixed a real divergence (sub-window SE mismatch) — `docs/PHASE4A_AUDIT_REPORT.md` |
| Shock DNA (Phase 4B) | **EXACT** (post-review) | `shock_dna.py`/`ShockDNAEngine.mqh` — two code-review passes found and identically fixed six real defects (onset-bypass, dropped `transmission_available` field, regime-truthiness bug and its default-value counterpart, inconsistent cross-asset gate, duplicated retracement math) in *both* files — `docs/PHASE4B_SHOCK_DNA_REPORT.md` |
| Regime Classifier / Volatility Seriality (Phase 3) | **NOT COMPARABLE** | No separate MQL5-vs-Python parity claim was made for these — they were built MQL5-first with hand-derived formulas, not ported from a Python reference (`docs/PHASE3_REGIME_VOLATILITY_REPORT.md`) |
| Market State (Phase 2) | **NOT COMPARABLE** | A pass-through aggregation struct with no independent Python reference to compare against |
| All Phase 5 research | **N/A** | Python-only by design (`research/information_value/`); has no MQL5 counterpart to compare, and per its own authorization was never intended to produce one absent real-data evidence |

This audit did not re-derive the Phase 4A/4B equivalence from scratch —
per the authorization's own instruction not to alter frozen logic, the
existing, already-adversarially-reviewed reports are the standing
evidence, cited here rather than reopened.

## 9. Look-ahead audit

Reviewed (not rerun, since Phase 4A/4B/5 logic is frozen) the existing
prefix-invariance/future-injection test suite:

- `test_shock_dna.py::test_15_future_data_injection_never_changes_past_snapshots`
- `test_targets.py::test_no_lookahead_future_injection`
- `test_feature_construction.py::test_serial_features_no_lookahead` /
  `test_transmission_features_no_lookahead`
- `test_lead_lag.py`'s own timestamp-misalignment/future-bar-rejection tests

All still pass (§confirmed in the full 145-test run, §13). No new
look-ahead violation was found in this audit. Layer 1's own tick loop
(`MarketData::OnTickUpdate()`) reads only `SymbolInfoTick()` at the
current instant — there is no historical-array read in the live path that
could be re-pointed at a future index, so a prefix-invariance test does
not apply to Layer 1 the way it does to the bar-history-based Layer 3
engines.

## 10. Data-integrity audit

| Failure mode | Layer 1 (live) behaviour | Layer 2 (`CDataIntegrityEngine`, dormant) behaviour |
|---|---|---|
| Impossible price (bid/ask<=0) | Tick rejected, `OnTick()` returns immediately (`MarketData.mqh:84`) | Would also reject (fail-closed NO-TRADE), richer reason string |
| Stale quote | **Not checked in Layer 1** | `Check()` compares `SYMBOL_TIME` against `m_maxStaleSeconds` |
| Abnormal spread | Only checked as a fixed ceiling inside `PreTradeAllowed()` (`m_maxSpreadPts`) | Additionally computes a rolling spread z-score |
| Stuck/duplicate feed | **Not checked in Layer 1** | `m_maxDuplicateStreak` tracks consecutive identical quotes |
| Symbol/trading disabled | **Not checked in Layer 1** | `SYMBOL_SELECT`/`SYMBOL_TRADE_MODE` checked explicitly |
| Missing bars / NaN / Inf | Not separately checked — MQL5's own `SymbolInfoTick()` either returns a tick or fails outright (`OnTickUpdate()` returns `false`, no partial/NaN tick is possible via this API) | N/A, same underlying API |

**Honest characterization:** Layer 1 has a real but *minimal* fail-closed
gate — it rejects the one failure mode (impossible price) that MQL5's
native tick API can actually produce, and does so correctly. It does
**not** have Layer 2's fuller staleness/z-score/stuck-feed detection,
because that entire layer is dormant. This is not a newly-discovered
defect — it is the expected, already-documented consequence of Layer 2
never being wired in, restated here with the specific mechanism traced
rather than assumed.

## 11. Compilation status

**MQL5 COMPILATION UNVERIFIED.** This environment was checked directly:
no `metaeditor`/`metaeditor64` binary on `PATH` or anywhere on the
filesystem, no Wine, Linux x86_64 host (MetaEditor/MetaTrader 5 ship as
Windows binaries only). No compilation was performed, attempted, or
claimed. Verification on the MQL5 side in this and every prior phase has
meant brace/paren/bracket balance-checking plus manual and AI code review
— never a real compiler. This does not change in Phase 6.

## 12. Strategy Tester status

**STRATEGY TESTER UNVERIFIED.** Same environment constraint as §11 — the
MT5 Strategy Tester is part of the Windows-only MetaTrader 5 terminal, not
available here. No smoke test, no tick processing run, no order-rejection
handling exercise, no forward or demo test was performed.

## 13. Adversarial and property-based tests

New, executable, repository-committed tests added this phase
(`python/tests/test_architecture_invariants.py`, 9 tests, all passing):
live-include-set regression lock, transitive-dormant-reachability check,
dormant-execution-authority scan, single-`CTrade`-instance check, risk-
clamp-site check, AFE-multiplier-bound check, `PreTradeAllowed()` gate-
completeness check, `#import`/`WebRequest` scan, Python↔MQL5 IPC-bridge
scan. These are **static-analysis tests over the real MQL5 source text**,
not simulated reimplementations of its logic — chosen deliberately so they
can never drift from what the actual `.mqh`/`.mq5` files say, and so they
require no compiler to run.

The authorization's own §13 "synthetic adversarial test battery"
(flat/trending/ranging markets, gaps, shock, missing data, daily/weekly
loss triggers, margin stress, etc.) and §14 property tests
("increasing spread cannot improve execution quality", etc.) describe
**behavioral** tests that require actually *running* the EA — against
live tick data, a Strategy Tester, or at minimum a compiled binary under a
test harness. None of those are available in this environment (§11/§12).
Building a parallel Python reimplementation of `RiskEngine`/`ExecutionEngine`
purely to test them in Python would itself violate the authorization's own
"do not create a competing architecture" instruction, and any such
reimplementation's own correctness would need to be verified against the
real MQL5 anyway — it would not be independent evidence. This category is
therefore reported honestly as **UNVERIFIED**, not worked around.

Full existing Python suite (Phases 3–5's own research code, now including
this phase's architecture tests): **145/145 passing** (136 pre-existing +
9 new).

## 14. Research/production boundary

No contamination found. `research/information_value/` and
`python/autopsy_research/` are never imported by `MQL5/`; confirmed again
in §2/§13. Research CSVs (`research/information_value/data/`,
`research/information_value/results/`) are read only by Python modules in
the same tree. No research artifact writes to, or is read by, any MQL5
file.

## 15. Phase 5 evidence verification

Checked `docs/PHASE5_INFORMATION_VALUE_REPORT.md` and
`docs/PHASE5_DATA_PROVENANCE.md` against the authorization's own
checklist:

- "54 hypotheses tested" — matches report §18 exactly.
- "zero survived BH FDR" — matches report §18/§24 exactly ("0 of 54").
- "naive transmission finding invalidated by block permutation" — matches
  report §17 exactly (naive p=2.4×10⁻⁶, block-permutation empirical
  p=0.15).
- "XAUUSD data limitation documented" — matches `PHASE5_DATA_PROVENANCE.md`
  (close-only, weekend-row interpolation finding) and report §3/§22.
- "Shock DNA real-data evidence unavailable" — matches report §16
  ("BLOCKED, not attempted").
- "ATR-dependent real-data evidence unavailable" — matches report §13
  (Regime) and the Volatility Engine row of §24's classification table.
- "no MQL5 integration justified by Phase 5 results" — matches the PHASE
  5 STATUS block's own "MQL5: NOT STARTED (correctly so...)" line.

**No overstatement found.** The documentation does not claim more than
its own evidence supports anywhere this audit checked.

## 16. Production-readiness matrix

| Area | Status | Evidence | Blocker |
|---|---|---|---|
| Architecture | VERIFIED | §2–§7 — single risk/execution/sizing authority, zero dormant reachability, all traced | none |
| MQL5 Compilation | UNVERIFIED | §11 — no compiler available in this environment | Need MetaEditor or an MT5-capable host |
| Strategy Tester | UNVERIFIED | §12 — not available in this environment | Need an MT5 terminal with Strategy Tester |
| Execution Path | VERIFIED | §5 — full trace, single funnel, single `CTrade` instance | none |
| Risk Invariants | VERIFIED | §6 — all 10 (A–J) traced to real code | none |
| Data Integrity | PARTIALLY VERIFIED | §10 — minimal live gate confirmed working; fuller gate exists only in dormant Layer 2 | Wiring decision, not a defect |
| Look-Ahead Protection | VERIFIED (Layer 3 research); NOT APPLICABLE (Layer 1) | §9 | none |
| Dormant Isolation | VERIFIED | §7, automated | none |
| Python/MQL5 Parity | VERIFIED (Phase 4A/4B only) | §8 | Phase 3 has no parity claim to make |
| Research Validation | VERIFIED (methodology); FAILED (real-data support) | §15 — Phase 5's own honest 0/54 result | Real-data evidence itself, not the process |
| Real-Data Validation | FAILED | Phase 5: 0/54 hypotheses survive FDR | Awaiting either better data or a different research question |
| Forward Testing | UNVERIFIED | Never attempted | Needs a running MT5 instance |
| Broker Validation | UNVERIFIED | Never attempted | Needs a demo/live account connection |
| Documentation | VERIFIED (post-fix) | §3/§17 — the Layer-count gap found and corrected this phase | none remaining |

## 17. Defects found

1. **Documentation gap (§3):** `EA_DESCRIPTION.md` accounted for 33 of 36
   dormant modules; `ORBEngine.mqh`/`NoiseAreaEngine.mqh` (two complete,
   independent, execution-isolated paper-sourced strategies) had no entry
   in the layer taxonomy.
2. **Test-authoring defects (self-contained to this phase's own new
   test file, caught and fixed before commit — not repository defects):**
   an initial version of `test_risk_percent_is_clamped_at_its_only_write_site`
   flagged the constructor's own hardcoded default as a second "write",
   and `test_no_python_mql5_ipc_bridge` flagged its own source file for
   containing the very pattern strings it searches for. Both were logic
   errors in the newly-written test, not findings about the codebase;
   both fixed immediately (see §19).

No defect was found in `MQL5/Include/AutopsyX/` or
`MQL5/Experts/AutopsyX/` themselves this phase — the audit's own
hypotheses about where a problem might exist (duplicate risk authority,
bypassable gates, dormant leakage) were all falsified by the trace.

## 18. Defects fixed

1. **`EA_DESCRIPTION.md`** — added the two uncatalogued modules under a
   clearly-labeled heading, corrected the dormant-module count from 33 to
   36. Low-risk (documentation only), in scope (Phase 6 audit finding),
   independently verifiable (file count now matches `ls` output).
2. **`test_risk_percent_is_clamped_at_its_only_write_site`** — rewritten
   to distinguish the constructor's literal default from the
   caller-driven, clamped `Configure()` write, asserting the real
   invariant (exactly one clamped, parameter-derived write) rather than a
   naive "exactly one write total" count.
3. **`test_no_python_mql5_ipc_bridge`** — excludes its own file from the
   scan (a test that searches for pattern X must not match on its own
   source code defining pattern X).

Both test fixes were reproduced (ran the failing test, saw the exact
false-positive), root-caused, fixed with the minimum change, and
re-verified — the full architecture-test file and the full 145-test repo
suite both pass after the fix (§13).

## 19. Remaining blockers

In order of what must happen before this system could reasonably be
called forward-testable, per the authorization's own principle of
preferring UNVERIFIED to PROBABLY SAFE:

1. **A real MQL5 compile.** Nothing in this or any prior phase has ever
   compiled this code. Type mismatches, scope/lifetime bugs, enum-ordinal
   mismatches, and const-correctness violations are all classes of defect
   that balance-checking and manual review cannot catch (`docs/
   VERIFICATION_STATUS.md` already says this; still true).
2. **A Strategy Tester smoke run** (§12/§13) — initialization, tick
   processing, order construction/rejection handling, position
   management, emergency controls, journal output, clean shutdown — none
   of this has ever executed.
3. **Real behavioral adversarial tests** (§13) against a compiled binary —
   the flat/trend/range/gap/shock/missing-data market-condition battery
   and the daily/weekly/consecutive-loss/margin risk-condition battery the
   authorization asks for, which require an actual running instance to
   exercise, not a source-text scan.
4. **A decision on Layer 2's data-integrity gap** (§10) — Layer 1's
   minimal tick gate is real and correctly fail-closed, but materially
   thinner than what `CDataIntegrityEngine` would provide if ever wired;
   this is a design choice to revisit, not a defect to silently patch.
5. **Real-data evidence for any dormant intelligence layer** (§15/§16) —
   Phase 5 answered honestly that none currently exists at daily
   granularity for the layers it could test, and three layers (Regime's
   ATR classification, `CVolatilityEngine`, Shock DNA) remain untested at
   all for lack of OHLC XAUUSD data.

## 20. Exact next steps

1. Obtain access to a Windows host (or Wine-compatible MetaEditor build)
   and compile the full EA. Report every error/warning verbatim — do not
   silently fix without a separate reproduce/root-cause/regression-test
   cycle per the fix policy already established in this repository.
2. Once compiled, run the MT5 Strategy Tester smoke test from §12 on
   historical data for the intended symbol — initialization through clean
   shutdown, no optimization, no parameter tuning.
3. Only after a clean smoke test, build the behavioral adversarial battery
   from §13 against the compiled binary.
4. Decide, as an explicit architectural decision (not a Phase 6 or Phase 7
   task), whether Layer 2's `CDataIntegrityEngine` should be wired into
   Layer 1 given the gap in §10 — independent of any intelligence-layer
   question, since data integrity is a foundational concern the live
   system currently under-covers.
5. Do not wire any of Layers 2/3/4 into live execution based on this
   report. This report found the architecture sound; it did not find any
   new evidence that the dormant layers add value (that remains Phase 5's
   own honest "insufficient evidence" finding, unchanged).

---

**This report makes no profitability claim, no readiness-for-live-money
claim, and no claim that the code compiles.** It establishes, with a
traceable path for each claim, what is architecturally true today.
