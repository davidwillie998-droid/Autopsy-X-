# Module Wiring Map (Section B)

**Applies to commit:** 805ac80
**Method:** not a description of intent — derived mechanically from the
actual `#include` graph and global-instance declarations in
`AutopsyX_FlipDemon_Extreme.mq5`, cross-checked against every `.mqh`
file's own internal `#include`s to rule out transitive wiring. Commands
used are reproducible: `grep` over `#include` lines and `g_[A-Za-z0-9_]+;`
declarations. This is not an audit of correctness (Section A covers the
one path that matters for risk) — it is an audit of **what is even
reachable from the live EA at all.**

---

## Headline finding

Of **53** files in `MQL5/Include/AutopsyX/`, exactly **25** (24 engine
classes + `Defs.mqh`) are `#include`d, directly or transitively, from
`AutopsyX_FlipDemon_Extreme.mq5`. The other **28** are compiled by
nothing, referenced by nothing, and reachable from nothing in the live
EA — confirmed by checking not just the main file's own `#include` list,
but every wired file's own internal includes, to rule out an indirect
path in.

**This was already the stated, repeated design intent throughout this
build** ("nothing gets wired into the live OnTick loop as part of this
build" appears in this session's own standing rules) — this document
exists to make that intent a checkable fact rather than a claim, and to
give a single place that lists exactly what is and isn't live.

There is also no `OnTradeTransaction` handler in the file at all —
confirmed by grepping for MQL5's four standard event-handler signatures
(`OnInit`, `OnDeinit`, `OnTick`, `OnTimer` all exist; `OnTradeTransaction`
does not). Anything built assuming trade-transaction-driven reconciliation
runs is dormant for that reason specifically, not merely unreferenced.

---

## Wired (live) — 24 engine instances, instantiated as globals and called from OnInit/OnTick/OnTimer

| File | Class | Global instance(s) |
|---|---|---|
| MarketData.mqh | CMarketData | g_md |
| Momentum.mqh | CMomentumEngine | g_mom |
| Microstructure.mqh | CMicrostructureEngine | g_micro |
| Liquidity.mqh | CLiquidityEngine | g_liq |
| Regime.mqh | CRegimeEngine | g_regime, g_regimeHtf |
| SignalScore.mqh | CSignalScorer | g_scorer |
| FlipEngine.mqh | CFlipEngine | g_flip |
| AntiChop.mqh | CAntiChopEngine | g_chop |
| RiskEngine.mqh | CRiskEngine | g_risk |
| EmergencyControls.mqh | CEmergencyControls | g_emergency |
| EntryEngine.mqh | CEntryEngine | g_entryEngine |
| ExecutionEngine.mqh | CExecutionEngine | g_exec |
| ExitEngine.mqh | CExitEngine | g_exit |
| SniperEngine.mqh | CSniperEngine | g_sniper |
| OrderFlow.mqh | COrderFlowEngine | g_orderFlow |
| VolumeProfile.mqh | CVolumeProfileEngine | g_volProfile |
| Footprint.mqh | CFootprintEngine | g_footprint |
| Pulse.mqh | CPulseEngine | g_pulse |
| Heatmap.mqh | CHeatmapEngine | g_heatmap |
| AdaptiveFlipEngine.mqh | CAdaptiveFlipEngine | g_afe |
| VWAPEngine.mqh | CVWAPEngine | g_vwap |
| TradeAutopsy.mqh | CTradeAutopsy | g_autopsy |
| Statistics.mqh | CStatistics, CAccuracyEngine | g_stats, g_accuracy |
| Dashboard.mqh | CDashboard | g_dash |

`Defs.mqh` is a shared type/enum header with no class of its own —
included everywhere, correctly not an "engine."

This set is fully closed: none of these 24 files' own internal
`#include`s reach outside this set (verified per-file, not assumed).

---

## Dormant — 28 files, zero reachability from the live EA

Grouped by which phase of this build produced them. "Dormant" here means
precisely: not `#include`d by `AutopsyX_FlipDemon_Extreme.mq5`, and not
`#include`d by anything that IS — the code exists on disk, was balance-
checked and code-reviewed as a standalone module at build time (per this
session's own established pattern for every phase), but is not compiled
into the EA that would actually run.

### FLIPDEMON EXTREME rewrite, Phases 2-6 (TradeThesis/execution-layer build)

| File | Class | Built for |
|---|---|---|
| StructureEngine.mqh | CStructureEngine | BOS/CHoCH/MSS structure classification (signal-only, verified in Phase 6 of the institutional build) |
| CompositeDirection.mqh | CCompositeDirectionEngine | Weighted multi-engine directional vote |
| ExecutionEligibility.mqh | CExecutionEligibility | Thesis-quality + composite-direction gate (funnels into RiskEngine, which itself IS wired independently) |
| TradeLifecycle.mqh | (lifecycle state machine) | Position lifecycle state tracking beyond the simple `g_posState` struct already used live |
| DuplicateGuard.mqh | (duplicate-order guard) | Order duplication protection at the execution layer |
| RestartRecovery.mqh | (restart recovery) | Re-hydrating position state after an EA/terminal restart |
| TradeReconciliation.mqh | CTradeReconciler | `OnTradeTransaction`-driven reconciliation — **moot regardless of wiring, since no `OnTradeTransaction` handler exists in this file at all** |
| MonteCarlo.mqh | (Monte Carlo simulator) | Report-only Monte Carlo projection over closed-trade history |
| KellyRuin.mqh | CKellyRuinEngine | Report-only Kelly-fraction diagnostic — explicitly documented in its own file header as "NEVER let this class's output authorize or size a live trade," so its dormancy is by design, not an oversight |

### Institutional engine build, Phases 2-10 (this session's later, larger build)

| File | Class | Layer |
|---|---|---|
| DataIntegrity.mqh | CDataIntegrityEngine | Layer 0 — data-quality gate |
| MacroRegime.mqh | CMacroRegimeEngine | Layer 1 — macro/cross-asset regime |
| VolatilityEngine.mqh | CVolatilityEngine | Layer 2 — volatility regime |
| LiquidityScoreEngine.mqh | CLiquidityScoreEngine | Layer 3 — liquidity scoring |
| TickDirectionEngine.mqh | CTickDirectionEngine | Layer 4 — Lee & Ready tick/quote classification |
| PriceImpactEngine.mqh | CPriceImpactEngine | Price impact |
| InformationContentEngine.mqh | CInformationContentEngine | Signal-pressure / order-flow vocabulary layer |
| AlphaEngine.mqh | CAlphaEngine | Composite alpha score |
| DrawdownEngine.mqh | CDynamicDrawdownEngine | Dynamic drawdown state + LADD |
| HiddenRiskDetector.mqh | CHiddenRiskDetector | Building-but-not-yet-realized risk |
| CrisisEngine.mqh | CCrisisEngine | Crisis/black-swan severity ladder |
| CapacityCrowdingEngine.mqh | CCapacityCrowdingEngine | Capacity + self-crowding proxy |
| TradePermissionMatrix.mqh | CTradePermissionMatrix | 15-gate final decision aggregator |
| DynamicPositionSizing.mqh | CDynamicPositionSizing | Size-down-only multiplier stack |
| PerformanceAttribution.mqh | CPerformanceAttribution | Regime/direction/flip-origin P&L attribution |
| DrawdownAnalytics.mqh | CDrawdownAnalytics | Historical drawdown-episode analysis |
| ExplainabilityEngine.mqh | CExplainabilityEngine | Per-decision JSON explanation builder |
| ExplainabilityLog.mqh | CExplainabilityLog | JSONL persistence for the above |
| InstitutionalDashboard.mqh | CInstitutionalDashboard | Dashboard v3 (7-panel institutional view) |

---

## What this means in practice

- **The live EA today trades on exactly the FLIPDEMON EXTREME v1 signal/risk stack** (momentum, microstructure, liquidity, regime, signal score, flip/anti-chop, order-flow suite, AFE, VWAP) gated by `RiskEngine`/`EmergencyControls`, sized by `CalculateLotSize()` (Section A), logged by `TradeAutopsy`/`Statistics`, displayed by `Dashboard`.
- **None of the institutional-engine build (LADD, Crisis Mode, the 15-gate permission matrix, Dashboard v3, etc.) affects a single live trading decision** in the current `.mq5` file. It is real, reviewed, tested-where-testable (Python side) code sitting inert on disk.
- **None of the FLIPDEMON EXTREME Phase 2-6 execution-layer redesign (TradeThesis/CompositeDirection/ExecutionEligibility/lifecycle/reconciliation) is live either** — the EA still runs on the original, simpler entry/exit gate chain from the pre-institutional-build architecture.
- Wiring any of the 28 dormant files into `OnInit`/`OnTick`/`OnTimer` (and, for `TradeReconciliation.mqh` specifically, adding an `OnTradeTransaction` handler that doesn't currently exist) is future work, explicitly out of scope for every phase of this build per its own standing rules, and is not claimed as done anywhere in this repository's code.

**Correction against an earlier draft of this document:** an earlier version of this
paragraph claimed "every dormant file's own header already says so" (i.e. explicitly
flags its own not-wired status in a code comment). That was checked and found false -
only 5 of the 28 (`KellyRuin.mqh`, `CrisisEngine.mqh`, `TradePermissionMatrix.mqh`,
`DynamicPositionSizing.mqh`, `InstitutionalDashboard.mqh`) carry that specific
self-disclaimer in their own header text. The other 23 are dormant for the structural
reason established above (absent from the `#include` graph, confirmed by grep), not
because each one says so about itself - this document, not individual file comments,
is the authoritative source for wiring status.
