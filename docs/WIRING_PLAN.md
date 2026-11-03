# Wiring Plan for the 28 Dormant Modules

**Applies to commit:** d511a00
**Purpose:** order the 28 dormant modules (see `docs/MODULE_WIRING.md`)
for eventual live integration, by risk category first and real
dependency graph second - checked against actual method signatures in
this pass, not inferred from module names or phase numbers.

**Standing precondition (unchanged from every phase of this build):**
nothing in this plan is wired yet. This document is preparation for a
future decision, not a record of work done. Per `docs/VERIFICATION_STATUS.md`,
get FLIPDEMON EXTREME v1 (the current 25-file live stack) compiling clean
in a real MetaEditor before wiring anything from this list — a compile
failure after wiring 28 new files at once has too many possible suspects
to debug usefully.

---

## Cross-cutting finding: some dependencies aren't wireable as-is yet

Checked real signatures, not assumed. Two concrete accessor gaps exist
between what several Tier 2/3 engines expect as input and what their
upstream engines currently expose publicly:

- **`CHiddenRiskDetector::Update()`** takes `spreadZScore` as a raw
  `double`. `CDataIntegrityEngine`'s own spread-z-score calculation
  (`RollingSpreadZScore()`) is **private** — `Check()` uses it internally
  but never returns it. Wiring `HiddenRiskDetector` for real requires
  either exposing that z-score as a new public accessor on
  `CDataIntegrityEngine`, or computing it separately.
- **`CHiddenRiskDetector::Update()`** also takes `tickActivityScore` and
  (elsewhere) engines expect `velocityScore` as standalone doubles.
  `CLiquidityScoreEngine::ComputeScore()` computes both internally but
  returns only the final blended score plus a human-readable breakdown
  **string** — the individual component scores are not separately
  accessible.

Neither gap is a bug (both engines were reviewed and are correct for
what they document); it's a real, previously-undiscovered wiring cost
that a plan built from method names alone would have missed. Budget a
small accessor-exposure pass (new `public:` getters, no logic change) as
part of wiring Tier 2, not as a surprise mid-wire.

---

## Tier 0 — Infrastructure prerequisite (blocks one specific module)

| Item | Why |
|---|---|
| Add an `OnTradeTransaction` handler | Does not exist in the file at all (confirmed, `docs/MODULE_WIRING.md`). `TradeReconciliation.mqh` is unusable until this exists — not a wiring decision, a missing event handler. |

---

## Tier 1 — Pure risk-reducers / self-contained informational engines

No dependency on any other dormant module. Each is independently
wireable, independently testable, and — for the risk-reducers — can
only ever make the bot more conservative, never less.

Off-switch default follows this codebase's own existing convention:
every live feature ships as `input bool InpUseX = false` (see
`InpUseVWAPExit`, `InpUseAdaptiveFlipEngine`, `InpUseImpactCostSizing`,
`InpUseHeatmap` — all default OFF today). Every module below gets the
same treatment, no exceptions, including the pure risk-reducers —
"reduces risk when it runs" is not the same claim as "safe to turn on
by default the moment it's wired," and this codebase has never made
that exception for anything else.

| Module | Category | Depends on (live only) | Off-switch input (default) | Acceptance test |
|---|---|---|---|---|
| `DataIntegrity.mqh` | Risk-reducer | `CMarketData` (live) | `InpUseDataIntegrityGate` (OFF) | Feed a stale/impossible quote in a demo run; confirm `Check()` returns false and no entry is attempted. |
| `DuplicateGuard.mqh` | Risk-reducer | Execution layer (live) | `InpUseDuplicateGuard` (OFF) | Attempt two entries in immediate succession under test conditions; confirm the second is blocked. |
| `VolatilityEngine.mqh` | Informational (feeds Tier 2/3) | `CMarketData`/ATR (live) | `InpUseVolatilityEngine` (OFF) | Compare `Classify()`'s output against a manually-computed ATR percentile on a known price series; confirm agreement. |
| `MacroRegime.mqh` | Informational, no live consumer yet | Broker Market Watch (live) | `InpUseMacroRegime` (OFF) | Configure a real cross-asset symbol; confirm `Bias()` returns a real reading, and `AX_MACRO_DATA_UNAVAILABLE` (never a guess) when the symbol isn't selectable. |
| `TickDirectionEngine.mqh` | Informational (feeds Tier 2) | `CMarketData` ticks (live) | `InpUseTickDirectionEngine` (OFF) | Feed a known sequence of up/down ticks; confirm tick-test classification matches by hand. |
| `PriceImpactEngine.mqh` | Informational (feeds Tier 2/3) | Needs a new `RegisterExecution()` call added at the real fill point in `ExecutionEngine`/main `.mq5` | `InpUsePriceImpactTracking` (OFF) | Confirm a registered execution's impact reading appears after its configured window elapses, on a demo fill. |

---

## Tier 2 — Depend on Tier 1 outputs (wire only after Tier 1 + the accessor-gap fix above)

| Module | Category | Depends on | Off-switch input (default) | Acceptance test |
|---|---|---|---|---|
| `LiquidityScoreEngine.mqh` | Informational (feeds Tier 3+) | `CVolatilityEngine` (Tier 1), `CMarketData`/`CMicrostructureEngine` (live) | `InpUseLiquidityScoreEngine` (OFF) | Confirm `ComputeScore()`'s breakdown string components move in the expected direction as spread/tick-activity synthetically vary in a demo test. |
| `InformationContentEngine.mqh` | Informational | `COrderFlowEngine` (live), `CTickDirectionEngine` (Tier 1) | `InpUseInformationContentEngine` (OFF) | Confirm `SignalPressure()` tracks `COrderFlowEngine`'s own imbalance ratio 1:1 (it's a deliberate thin relabel — see its own file header). |
| `DrawdownEngine.mqh` | Risk-reducer | `CVolatilityEngine` (Tier 1), `CLiquidityScoreEngine` (this tier), live execution-quality tracking | `InpUseDynamicDrawdownEngine` (OFF) | Force a synthetic equity drawdown in a demo run; confirm the state ladder (NORMAL→CAUTION→…→HALT) advances at the configured thresholds. |
| `HiddenRiskDetector.mqh` | Risk-reducer | `DataIntegrity`'s spread z-score (needs the accessor fix above), `CVolatilityEngine`, `CPriceImpactEngine`, `CLiquidityScoreEngine`'s components (needs the accessor fix above), `CRiskEngine.ConsecutiveLosses()` (live) | `InpUseHiddenRiskDetector` (OFF) | Synthetically widen spread + degrade execution quality together; confirm the composite score rises and crosses `ELEVATED`/`SEVERE` at the configured thresholds. |

---

## Tier 3 — Signal-generating (these change what the bot decides to trade, not just how much)

Wire one at a time, each with its own demo-trading observation window
before the next — this tier is where live *behavior* first changes,
not just risk posture.

| Module | Depends on | Off-switch input (default) | Acceptance test |
|---|---|---|---|
| `StructureEngine.mqh` | `CMarketData` bars (live) only | `InpUseStructureEngine` (OFF) | Compare BOS/CHoCH/MSS classification against a manually-marked-up chart for a known historical window. |
| `AlphaEngine.mqh` | `MacroRegime` (Tier 1), `LiquidityScoreEngine`/`VolatilityEngine` (Tier 2/1), `InformationContentEngine` (Tier 2), `PriceImpactEngine` (Tier 1) | `InpUseAlphaEngine` (OFF) | Confirm `ComputeAlphaScore()`'s `finalScore` never exceeds 100 or goes negative across a demo session; spot-check the breakdown string against the component reads. |
| `CompositeDirection.mqh` | Existing live directional engines (Regime/Momentum/OrderFlow, already live) plus VP-MACD/News Defense inputs, which per the module's own header are explicitly `DATA_UNAVAILABLE`-safe placeholders (no such modules exist in this build) | `InpUseCompositeDirection` (OFF) | Confirm a hard News veto (if ever wired) blocks a vote outright; confirm `AX_COMPOSITE_DATA_UNAVAILABLE`/`INSUFFICIENT_EVIDENCE` never silently resolve to a direction. |
| `ExecutionEligibility.mqh` | `CompositeDirection` (this tier), `CRiskEngine` (already live, reused not duplicated) | `InpUseExecutionEligibilityGate` (OFF) | Feed a thesis whose direction disagrees with its own composite-direction input; confirm it fails closed (per its own "fail closed" file header) rather than defaulting eligible. |
| `CrisisEngine.mqh` | `VolatilityEngine` (Tier 1), `DrawdownEngine` (Tier 2), `HiddenRiskDetector` (Tier 2), `DataIntegrity` pass/fail (Tier 1) | `InpUseCrisisEngine` (OFF) | Force a synthetic combination (shock volatility + severe drawdown) in a demo run; confirm the ladder reaches `CRISIS`/`BLACK_SWAN` only under genuinely compound conditions, not a single input alone. |
| `CapacityCrowdingEngine.mqh` | `LiquidityScoreEngine`/`PriceImpactEngine` (Tier 1/2) for capacity; live VWAP + ATR for the crowding proxy | `InpUseCapacityCrowdingEngine` (OFF) | Register several same-direction entries in a short window on a demo account; confirm `CrowdingProxyScore` rises measurably. |

---

## Tier 4 — Capstone aggregators (wire last among the new stack — everything above is an input to these)

| Module | Depends on | Off-switch input (default) | Acceptance test |
|---|---|---|---|
| `TradePermissionMatrix.mqh` | All 15 gates' real inputs: `DataIntegrity`, `CrisisEngine`, `DrawdownEngine`, `RiskEngine` breach flags (live), `VolatilityEngine`, `CompositeDirection`, `ExecutionEligibility`, `LiquidityScoreEngine`, `PriceImpactEngine`, `AlphaEngine`, `CapacityCrowdingEngine` | `InpUseTradePermissionMatrix` (OFF) | Force each of the 8 hard gates to fail one at a time in a controlled test; confirm the decision lands at exactly `HALT` (for the 5 HALT-tier gates) or `NO_TRADE` (for the 3 NO_TRADE-tier gates) per `docs/RISK_INVARIANT_AUDIT.md`-style tracing, not just "it blocks." |
| `DynamicPositionSizing.mqh` | `TradePermissionMatrix`'s decision, `DrawdownEngine`, `CrisisEngine`, `AlphaEngine`, `CapacityCrowdingEngine` | `InpUseDynamicPositionSizing` (OFF) — meaningless while `InpUseTradePermissionMatrix` is OFF, since it consumes that decision as an input; document the dependency at the input-parameter level too, not just here | Confirm `Compute()`'s `finalRiskPercent` never exceeds `baseRiskPercent` across every combination tested above (same "size-down only" invariant class as Section A) - this is the one module in this tier that touches real position sizing, so it inherits Section A's audit standard, not a lighter one. |

---

## Tier 5 — Risk-neutral (reporting/analytics/display) — safe to wire anytime, listed last because most of them need Tier 3/4 to have real data worth showing

Several of these (analytics/reporting) have no live trading behavior to
gate at all — the off-switch here controls whether they COMPUTE and
LOG/DISPLAY, not a risk exposure. Still default OFF, matching the
codebase's blanket convention rather than carving out an exception for
"this one can't hurt anything."

| Module | Depends on | Off-switch input (default) | Acceptance test |
|---|---|---|---|
| `TradeLifecycle.mqh` | Existing `g_posState` (live) | `InpUseTradeLifecycle` (OFF) | Confirm state transitions match `g_posState`'s own lifecycle 1:1 on a demo session — a divergence here would itself be a bug worth catching before trusting either. |
| `RestartRecovery.mqh` | Live position/account state | `InpUseRestartRecovery` (OFF) | Restart the EA mid-position on a demo account; confirm state is correctly re-hydrated, not reset. |
| `TradeReconciliation.mqh` | Tier 0 (`OnTradeTransaction`) | `InpUseTradeReconciliation` (OFF) | Manually close a position outside the EA (e.g. from the terminal) on a demo account; confirm reconciliation detects and logs the discrepancy. |
| `MonteCarlo.mqh` | `TradeAutopsy` ledger (live) | `InpUseMonteCarloReport` (OFF) | Run against a real closed-trade history; sanity-check the projection against a hand-computed simple case. |
| `KellyRuin.mqh` | `TradeAutopsy`/`Statistics` (live) | `InpUseKellyReport` (OFF) | Confirm its own report-only invariant holds: grep the call site to verify its output is never passed into `CalculateLotSize()` or any sizing path. |
| `PerformanceAttribution.mqh` | `TradeAutopsy` ledger (live) | `InpUsePerformanceAttribution` (OFF) | Cross-check one regime bucket's win rate by hand against the raw CSV. |
| `DrawdownAnalytics.mqh` | `TradeAutopsy` ledger (live) | `InpUseDrawdownAnalytics` (OFF) | Cross-check one detected episode's depth/duration by hand against the raw CSV. |
| `ExplainabilityEngine.mqh` + `ExplainabilityLog.mqh` | `TradePermissionMatrix`/`DynamicPositionSizing` (Tier 4) for real content | `InpUseExplainabilityLog` (OFF) | Confirm the JSONL log parses as valid JSON per line on a real run. |
| `InstitutionalDashboard.mqh` | Most of Tiers 1-4 for real panel data (has its own "NO DATA YET" guard for what isn't wired yet — see its own code-review fix) | `InpUseInstitutionalDashboard` (OFF) | Visual check against `g_dash`'s existing panel for no object-name or screen-position collision (already verified structurally in `docs/MODULE_WIRING.md`; this is the live-render confirmation). |

---

## Summary ordering

```
Tier 0 (infra)      → OnTradeTransaction handler
Tier 1 (standalone) → DataIntegrity, DuplicateGuard, VolatilityEngine,
                       MacroRegime, TickDirectionEngine, PriceImpactEngine
Tier 2 (needs T1)    → LiquidityScoreEngine, InformationContentEngine,
                       DrawdownEngine, HiddenRiskDetector
Tier 3 (signal)      → StructureEngine, AlphaEngine, CompositeDirection,
                       ExecutionEligibility, CrisisEngine, CapacityCrowdingEngine
Tier 4 (capstone)    → TradePermissionMatrix, DynamicPositionSizing
Tier 5 (reporting)   → TradeLifecycle, RestartRecovery, TradeReconciliation,
                       MonteCarlo, KellyRuin, PerformanceAttribution,
                       DrawdownAnalytics, ExplainabilityEngine,
                       ExplainabilityLog, InstitutionalDashboard
```

Each module gets its own review pass at wiring time (compile clean,
balance-check, code-review the actual wiring diff — not just the
module in isolation, since wiring is exactly where a previously-correct
standalone module can be miswired) — the same discipline this entire
build has used for every phase so far.
