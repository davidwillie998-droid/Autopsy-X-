# AUDIT — "AUTOPSY X 10X Market Intelligence System" request

**Phase:** 1 of 20 (per the request's own development sequence).
**Rule applied from the request itself:** "Do not modify production
logic until the audit is complete... implement Phase 1 only... wait for
verification before moving to Phase 2." This document is that Phase 1
deliverable. No code has been written or modified for this request.
No production logic has changed.

**Method:** derived from the actual files on disk (headers, class
lists, `docs/MODULE_WIRING.md`'s existing `#include`-graph audit,
targeted greps) — not from memory of what was intended.

---

## Headline finding

Most of the 26 engines the request asks for already exist in this
repository, built during the "institutional engine upgrade" earlier
in this project, reviewed and balance-checked the same way every file
in this codebase is, and sitting dormant (never wired into `OnTick`)
by explicit, repeated design choice. Two of the request's items
(Leverage Path Engine, QQQ/TQQQ/NDX Specialization) describe an
instrument class — US leveraged equity ETFs — this EA has never
traded and has no data path for at all. Building those now is a scope
expansion, not an extension of existing dormant work, and needs an
explicit decision before any code gets written for them.

Writing 20+ new files that duplicate this existing, reviewed work
would violate the request's own audit rules ("do not create duplicate
risk engines," "do not create duplicate execution engines," "identify
duplicate functionality," "do not rewrite working components
unnecessarily"). The correct Phase 2 is therefore mostly **wiring,
extending, and renaming/exposing fields on existing dormant engines**,
plus a much smaller set of genuinely new modules for the handful of
capabilities that don't exist anywhere in this codebase yet.

---

## A. Existing architecture (relevant to this request)

Full inventory is `docs/MODULE_WIRING.md` (53 files, 24 wired live +
`Defs.mqh`, 28 dormant). This section only maps the request's 26
numbered engines against what's already on disk.

| Request's engine (§ number) | Closest existing file(s) | Status |
|---|---|---|
| §3 Market State Engine | `MarketData.mqh`, `Momentum.mqh`, `Microstructure.mqh`, `Liquidity.mqh`, `StructureEngine.mqh`, `VolumeProfile.mqh`, `VWAPEngine.mqh`, `OrderFlow.mqh` | Features exist, scattered across engines. No single state-vector struct. |
| §4 Regime Engine | `Regime.mqh` (TREND/RANGE/BREAKOUT), `MacroRegime.mqh` (cross-asset) | Overlapping, not identical. No R1-R8 taxonomy, no REGIME_CONFIDENCE/STABILITY/AGE/TRANSITION_PROBABILITY fields. |
| §5 Trend Efficiency Engine | none | **Gap.** No Kaufman-style efficiency ratio, run-length, or failed-breakout-frequency stats anywhere. |
| §6 Volatility × Seriality Engine | `VolatilityEngine.mqh` (vol regime only) | Partial. No autocorrelation/variance-ratio/serial-correlation measurement, no V01-V07 taxonomy. |
| §7 Causality / Information Transmission | none | **Gap.** `MacroRegime.mqh` reads cross-asset symbols for context but does no lead-lag/transmission modeling. |
| §8 Shock DNA Engine | `CrisisEngine.mqh` (severity ladder only) | Partial. No shock-type classification or shock-fingerprint recording (MAE/MFE/recovery time). |
| §9 Information Surprise Engine | none | **Gap.** No economic-calendar module exists anywhere (`AlphaEngine.mqh`'s own header says so explicitly: "no News Defense module built yet"). |
| §10 Multi-Model Ensemble | `CompositeDirection.mqh` (weighted vote) | Partial. Not structured as 10 independently-labeled models each emitting confidence/expected-move/holding-time. |
| §11 Model Disagreement Engine | none | **Gap**, though `CompositeDirection.mqh`'s vote-counting is adjacent. |
| §12 Market Memory Engine | none | **Gap.** No nearest-neighbor historical-state retrieval anywhere. `TradeAutopsy.mqh`/`Statistics.mqh` keep the closed-trade ledger this would read from. |
| §13 State Transition Engine | none | **Gap.** Would sit on top of Regime + Market Memory, neither of which exists in the needed form yet. |
| §14 Tradeability Engine | `AlphaEngine.mqh::CalculateExpectedCost()` (EV-cost gate, already wired into AFE), `PriceImpactEngine.mqh` | **Strongest reuse case.** Expected-cost/EV logic already exists, diffused across two files rather than one named engine. |
| §15 Execution Alpha Engine | `SniperEngine.mqh` (precision-entry timing), `ExecutionEngine.mqh` | Partial. Nothing compares MARKET vs LIMIT vs RETEST vs VWAP-reclaim for expected edge. |
| §16 Leverage Path Engine | none | **Gap, and out of current instrument scope** — see Section D. |
| §17 Reflexivity Engine | none | **Gap.** Request itself says to return `DATA_UNAVAILABLE` when unmeasurable — matches `MacroRegime.mqh`'s existing honesty convention. |
| §18 Model Health Engine | `DrawdownAnalytics.mqh`, `PerformanceAttribution.mqh` (realized-performance decay only) | Partial. No feature-drift/prediction-error/edge-decay composite score. |
| §19 Self-Falsification Engine | `TradeAutopsy.mqh` (journal, no failure-mode taxonomy) | Partial. Substrate exists; classification logic doesn't. |
| §20 Model Kill Switch | `EmergencyControls.mqh` (risk/drawdown circuit breakers), `TradePermissionMatrix.mqh` (15-gate HARD/SOFT ladder) | **Strong reuse case.** This is close to already built. |
| §21-22 Master Decision Engine / Master Score | `TradePermissionMatrix.mqh` | **Strongest single match in the whole request.** Its own header calls it "the FINAL aggregation point... the one place safe to change the DECISION LADDER." A second, parallel decision engine would be exactly the duplicate risk/decision engine the request's own audit rules forbid. |
| §23 Confidence ≠ Risk | `DynamicPositionSizing.mqh` | **Already built**, field-for-field: `BASE_RISK × REGIME_MULTIPLIER × ...`, size-down-only, clamped stack. |
| §24 QQQ/TQQQ specialization | none | **Gap, and out of current instrument scope** — see Section D. |
| §25 XAUUSD specialization | `MacroRegime.mqh` (DXY/US10Y cross-asset reads), `VWAPEngine.mqh`, `Liquidity.mqh`/`StructureEngine.mqh` | Partial, consolidation candidate rather than new file. |
| §26 Data Quality Engine | `DataIntegrity.mqh` | **Already built**, near-exact match: VALUE/TIMESTAMP/SOURCE/FRESHNESS/VALIDITY/QUALITY_SCORE and the DATA_OK/DEGRADED/STALE/MISSING/CONFLICT taxonomy already exist. |
| §27 Decision Journal | `TradeAutopsy.mqh` (Journal v2), `ExplainabilityEngine.mqh` + `ExplainabilityLog.mqh` | **Already built.** |
| §28 Reason Codes | `TradePermissionMatrix.mqh` (string reasons per gate), `ExplainabilityEngine.mqh` (serializes them) | Mechanism exists; not yet in the exact `RC001`-style numeric-code format requested. |
| §29 No-Trade Intelligence | `TradePermissionMatrix.mqh` | Gate ladder already distinguishes most of these reasons structurally. |
| §30-33 Backtest/walk-forward/Monte Carlo/ablation | `python/autopsy_research/` (Phase 11 stress-test framework, alpha decay, strategy correlation), `MonteCarlo.mqh`, `KellyRuin.mqh` | Partial coverage confirmed. Walk-forward and ablation-specific harnesses not confirmed present — needs a direct look at `python/tests/` before claiming either way. |

---

## B. Reusable components (do not rebuild these)

- `TradePermissionMatrix.mqh` — final decision aggregation, HARD/SOFT
  gate ladder. This IS the Master Decision Engine the request asks
  for, under a different name.
- `DynamicPositionSizing.mqh` — the size-down-only multiplier stack
  IS the confidence-vs-risk separation the request asks for.
- `DataIntegrity.mqh` — IS the Data Quality Engine.
- `TradeAutopsy.mqh` + `ExplainabilityEngine.mqh`/`ExplainabilityLog.mqh` —
  IS the Decision Journal.
- `EmergencyControls.mqh` — IS the core of the Model Kill Switch
  (currently scoped to risk/drawdown triggers; would need extending,
  not replacing, to cover model-health/structural-break triggers too).
- `AlphaEngine.mqh` + `PriceImpactEngine.mqh` — carry the Tradeability
  Engine's EV/expected-cost logic already.
- `MacroRegime.mqh` — the honest "`DATA_UNAVAILABLE` rather than a
  fabricated reading" convention the request asks Reflexivity/Causality
  to follow already exists here; new engines should copy this pattern,
  not invent a new one.

## C. Conflicts / naming collisions to resolve before any new file

- Request's "Regime Engine" (R1-R8) vs. existing `CRegimeEngine`
  (TREND/RANGE/BREAKOUT) — same name space, different taxonomy. A new
  file cannot be called `AutopsyRegimeEngine.mqh` without colliding in
  intent with the existing `Regime.mqh`. Needs either: extend
  `Regime.mqh`/`MacroRegime.mqh` in place, or pick a name that makes
  the distinction obvious (e.g. `RegimeTaxonomyEngine.mqh`).
- Request's "Data Quality Engine" (`AutopsyDataIntegrityEngine.mqh`)
  is a near-exact rebuild of the already-existing `DataIntegrity.mqh`
  (`CDataIntegrityEngine`). Building it would be the literal duplicate
  the request's own audit instructions forbid.
- Request's "Master Decision Engine" (`AutopsyDecisionEngine.mqh`)
  duplicates `TradePermissionMatrix.mqh`'s stated role exactly.

## D. Missing interfaces / genuine gaps (no existing analog at all)

- Trend Efficiency Engine (§5)
- Causality / Information Transmission Engine (§7)
- Information Surprise Engine (§9) — additionally requires an
  economic-calendar data source. MT5 exposes a native
  `CalendarValueHistory()`/`CalendarEventById()` API that has not been
  explored anywhere in this codebase yet; this needs its own small
  research spike before a design can be written honestly, rather than
  assumed to be available.
- Model Disagreement Engine (§11) — entropy/conflict-source
  calculation over ensemble outputs.
- Market Memory Engine (§12) — nearest-neighbor historical-state
  retrieval. Buildable in MQL5 (bounded ring buffer + brute-force
  similarity, no external DB), but needs explicit scoping of the
  state-vector dimensionality and lookback window up front to keep it
  bar-level/cached rather than a tick-level cost sink (the request's
  own §36 performance rule).
- State Transition Engine (§13) — depends on both Regime and Market
  Memory existing first.
- Shock DNA Engine (§8) — shock-type classification and
  fingerprint recording; `CrisisEngine.mqh`'s severity ladder is the
  nearest relative but answers a narrower question (how bad, not what
  kind).
- Model Health Engine (§18) — feature-drift/prediction-error/edge-decay
  composite; existing analytics only cover realized P&L decay.
- Self-Falsification Engine (§19) — failure-mode taxonomy
  (WRONG_DIRECTION, FALSE_BREAKOUT, etc.) on top of the existing
  journal.
- Reflexivity Engine (§17) — genuinely new, and by the request's own
  instruction should mostly return `DATA_UNAVAILABLE` on this feed.

## E. Instrument-scope question (blocks §16 and §24 specifically)

This EA (`AutopsyX_FlipDemon_Extreme.mq5`) trades XAUUSD and major FX
only. There is no QQQ, TQQQ, NDX, or NQ symbol handling anywhere in
this codebase — confirmed by grep, zero matches. The request's
Leverage Path Engine (§16) and QQQ/TQQQ Specialization (§24) describe
a second instrument class (US leveraged equity ETFs) this project has
never touched.

This was already asked and answered earlier in this session
("Checking if the QQQ and TQQQ strategy was included" → not included,
this EA is XAUUSD/FX-only). Building §16/§24 now would be a genuine
scope expansion — new symbol handling, a new data feed relationship
(most retail MT5 brokers don't even list QQQ/TQQQ), and an entirely
untested instrument class — not an extension of the existing dormant
work. This is exactly the kind of decision the request's own Section 1
("only then implement... produce an architecture map before
implementation") reserves for explicit sign-off, and is called out
here rather than silently started or silently skipped.

## F. Proposed integration points (for genuinely new engines, once scoped)

New engines that get built should follow the two conventions already
established across every dormant institutional-engine file:
1. **Deliberately thin** — read already-computed values from existing
   engines (`Regime`, `VolatilityEngine`, `MacroRegime`,
   `InformationContentEngine`, etc.) rather than recomputing them.
2. **Signal, not action** — never touch `CTrade`, never close a
   position; report a score/state for `TradePermissionMatrix.mqh` (or
   its extension) to gate on.

None of this gets wired into `OnInit`/`OnTick`/`OnTimer` as part of
this work, matching every phase of this build to date.

## G. Files to create (genuinely new, pending Section E's answer)

- `TrendEfficiencyEngine.mqh` (§5)
- `CausalityEngine.mqh` (§7 — named for information transmission, not
  causal proof, matching the request's own caveat)
- `ShockDNAEngine.mqh` (§8)
- `InformationSurpriseEngine.mqh` (§9 — pending calendar-API research spike)
- `ModelDisagreementEngine.mqh` (§11, reading `CompositeDirection.mqh`'s vote)
- `MarketMemoryEngine.mqh` (§12)
- `StateTransitionEngine.mqh` (§13, depends on §12)
- `ModelHealthEngine.mqh` (§18)
- `FalsificationEngine.mqh` (§19, reads `TradeAutopsy.mqh`'s journal)
- `ExecutionAlphaEngine.mqh` (§15, extends `SniperEngine.mqh`'s scope)

## H. Files to modify (extend existing dormant engines rather than duplicate them)

- `Regime.mqh` / `MacroRegime.mqh` — extend toward the R1-R8 taxonomy
  and REGIME_CONFIDENCE/STABILITY/AGE/TRANSITION_PROBABILITY fields,
  rather than a new competing regime file.
- `VolatilityEngine.mqh` — add serial-correlation/variance-ratio/
  autocorrelation and the V01-V07 taxonomy.
- `AlphaEngine.mqh` / `PriceImpactEngine.mqh` — expose the existing
  EV/cost logic under an explicit `EDGE_TO_COST_RATIO`/tradeability
  naming, rather than building a new Tradeability Engine from scratch.
- `EmergencyControls.mqh` / `TradePermissionMatrix.mqh` — extend the
  kill-switch hierarchy to cover model-health and structural-break
  triggers, once `ModelHealthEngine.mqh` exists to feed it.
- `CompositeDirection.mqh` — extend toward the 10-model ensemble
  structure (DIRECTION/CONFIDENCE/EXPECTED_MOVE/EXPECTED_HOLDING_TIME
  per model) rather than a new ensemble file.

## I. Files that must remain untouched

Everything already wired live (the 24-file set in
`docs/MODULE_WIRING.md`'s "Wired" table) stays untouched for this
work, per the request's own §38 instruction ("Do not replace the
existing ICT structure logic, liquidity logic, sweep logic, FVG logic,
VWAP, VP-MACD, news defense, risk governor, trade management, journal
unless a genuine bug requires correction"). No production logic
changes as part of this audit, and none should change in Phase 2
either — new/extended engines stay dormant, matching this build's
standing rule that nothing gets wired into the live `OnTick` loop.

---

## Open questions before Phase 2 starts

1. **Instrument scope (§16, §24):** build the Leverage Path Engine and
   QQQ/TQQQ specialization as genuinely new, untested instrument-class
   work, or drop both from this pass since this EA doesn't trade that
   instrument class today?
2. **Economic calendar (§9):** authorize a short research spike into
   MT5's native `CalendarValueHistory()`/`CalendarEventById()` API
   before designing the Information Surprise Engine, since no part of
   this codebase has used it before and its actual data coverage
   (which brokers populate it, at what latency) is currently unknown?
3. **Phase ordering:** given how much of §2-33 is reuse/extension
   rather than new build, is the priority still the request's own
   listed order (Data Integrity + Market State first), or should the
   strongest-reuse items (Regime/Volatility extensions, Tradeability
   exposure) go first since they're the fastest to land safely?

No further implementation proceeds until these are answered, per the
request's own instruction to wait for verification between phases.

---

## Decisions confirmed (post-audit)

1. **Instrument scope (§16, §24):** dropped. Leverage Path Engine and
   QQQ/TQQQ/NDX specialization are explicitly out of scope for this
   project — see `docs/PHASE2_MARKET_STATE_REPORT.md`'s "Explicitly out
   of scope" section. If ever pursued, as a separate project, not a
   module on Flipdemon Extreme.
2. **Kept for future phases (not yet built):** Market Memory, State
   Transition, Model Health, Self-Falsification, Execution Alpha.
3. **Phase order:** proceeding in the request's own listed order
   (Phase 2: Data Integrity + Market State, done — see
   `docs/PHASE2_MARKET_STATE_REPORT.md`; Phase 3: Regime +
   Volatility/Seriality, next, pending sign-off).
4. **Economic calendar research spike (§9):** not yet actioned - still
   open, deferred until Phase 5 (Information Surprise) is actually next.
