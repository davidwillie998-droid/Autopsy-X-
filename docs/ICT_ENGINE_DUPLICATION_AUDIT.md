# ICT Engine Duplication Audit

**Repository:** `davidwillie998-droid/Autopsy-X-`  
**Working branch:** `claude/autopsy-flipdemon-extreme-l4ei3d`  
**Scope:** source-level audit of ICT structure, liquidity, dealing-range, FVG, order-block, ORB, reference-level and session-anchor calculations.  
**Execution impact:** documentation only. No trading logic, risk controls, inputs, or runtime behavior changed.

## Executive finding

The EA has repeated calculations, but several are not interchangeable. The most important distinction is between (1) duplicated data acquisition, (2) repeated algorithms with different definitions, and (3) independent evidence engines that happen to consume the same bars.

The safe target is one authoritative implementation per *definition*, not one generic calculation forced onto every consumer.

## Verified source findings

### 1. Swing calculations

- `StructureEngine.mqh` implements a two-bar-wing fractal sequence, collapses consecutive same-type pivots to the more extreme pivot, and classifies HH/LH/HL/LL. Its comparisons allow equal-price ties because the rejection checks use strict `<` / `>`.
- `Liquidity.mqh` independently scans fractal highs/lows and merges repeated touches into liquidity levels. This is a level-discovery algorithm, not a substitute for the alternating structure sequence.
- `D1InstitutionalLevels.mqh` and `W1InstitutionalDirection.mqh` each have their own two-wing swing scans for the last two highs/lows and EQH/EQL. They also each own a `CStructureEngine` instance for BOS/CHoCH/MSS trend context. Their local pivot comparisons use asymmetric strict tie handling (`<=` / `>=` on the older side and `<` / `>` on the newer side), so they are not definition-identical to `StructureEngine`.
- `PremiumDiscountEngine.mqh` independently selects the latest confirmed opposite-pivot pair, requires chronological BOS confirmation, and protects the strong extreme using closed-bar invalidation. Its purpose and acceptance criteria differ from both the structure sequence and raw liquidity pivots.

**Decision:** do not replace all four with a blind call to `CStructureEngine`. First define a shared, parameterized pivot primitive with explicit tie policy, confirmation/wing rules, and output timestamps. Keep the alternating structure sequence, liquidity clustering, EQH/EQL extraction, and premium/discount BOS validation as separate consumers. A shared primitive must not erase their distinct semantics.

### 2. FVG calculations

- `FairValueGapEngine.mqh` is the dedicated closed-bar FVG lifecycle engine. It applies configured lookback, age, minimum gap/ATR and displacement-body rules, and exposes directional readings including mitigation/retracement state.
- `D1InstitutionalLevels.mqh` independently scans up to 30 recent daily bars for the nearest unmitigated three-candle gap.
- `W1InstitutionalDirection.mqh` independently scans up to 12 recent weekly bars for similar three-candle gaps.
- The daily and weekly snapshots therefore do not implement the same lifecycle contract as the dedicated engine. They have timeframe-specific scan horizons and do not carry the same configured displacement/age qualification.

**Decision:** make the dedicated FVG lifecycle the canonical implementation, but first extend its API to support independent timeframe instances and timeframe-specific configuration. D1/W1 should consume separate D1/W1 readings from that engine, not reuse an M5 reading or collapse weekly gaps into the intraday lifecycle. Preserve any existing snapshot fields until all consumers are migrated.

### 3. Order blocks

- `OrderBlockEngine.mqh` is the dedicated structure-confirmed OB/breaker lifecycle.
- `W1InstitutionalDirection.mqh` also records the first recent opposing weekly candle as an OB candidate. Its own comments explicitly state that these candidates are not displacement-linked or validated order blocks.

**Decision:** retain the weekly opposing-candle data only if a consumer needs it, and name/type it as a *candidate zone*, never as a confirmed order block. Do not merge it into the confirmed OB lifecycle without the same displacement, structure, mitigation and invalidation rules.

### 4. Previous day/week reference levels

- `Liquidity.mqh` reads `iHigh/iLow` for completed D1 and W1 bars at shift 1.
- `AdvancedSessionORBEngine.mqh` repeats those four reads for its displayed/used PDH, PDL, PWH and PWL values.
- Both use the same completed-period shifts in the inspected code, so this is a strong candidate for shared retrieval.

**Decision:** introduce a small reference-level snapshot/cache keyed by symbol and the completed D1/W1 bar timestamps. Both engines consume the same snapshot. Fail closed on unavailable or stale data; do not substitute the forming D1/W1 bar. Keep each engine's own interpretation and scoring.

### 5. ORB implementations

- The EA includes and updates `AdvancedSessionORBEngine.mqh`.
- The EA's inspected include list does not include `ORBEngine.mqh`.
- `ORBEngine.mqh` remains a separate, substantial implementation with its own session-anchor logic and cross-asset confirmation helpers.

**Decision:** Advanced Session ORB is the active EA implementation in this branch. Do not delete `ORBEngine.mqh` until repository-wide include/reference checks cover every source, test, script and documentation consumer on this exact branch. If it is genuinely orphaned, retire it in a separate, reviewable change.

### 6. Session-anchor calculations

Similar session-anchor helpers exist in `VWAPEngine.mqh`, `ORBEngine.mqh` and `NoiseAreaEngine.mqh`. The inspected `NoiseAreaEngine` and legacy `ORBEngine` each carry deliberate independent copies with documented reasons. The main EA's active include list uses `VWAPEngine` and `AdvancedSessionORBEngine`, not the legacy `ORBEngine` or `NoiseAreaEngine`.

**Decision:** compare time-zone, broker-server-time, DST, rollover and "session immediately before timestamp" semantics before extracting a shared clock. A shared clock must accept an explicit time basis and session schedule; it must not silently convert all modules to the VWAP server-hour convention.

## Migration sequence

1. **Reference-level snapshot:** centralize completed D1/W1 high/low retrieval. This is the lowest-risk consolidation because both active consumers use the same shift-1 boundaries.
2. **Pivot primitive contract:** add tests for equal highs/lows, wide-range bars that are both a high and low pivot, consecutive same-type pivots, closed-bar confirmation, and series-array chronology. Migrate one consumer at a time while retaining its existing semantics.
3. **FVG multi-timeframe lifecycle:** instantiate independent M5/D1/W1 lifecycle states with separate configuration and preserve legacy snapshot fields during migration.
4. **OB candidate typing:** prevent weekly opposing-candle candidates from being mistaken for confirmed order blocks.
5. **ORB/session cleanup:** prove the legacy engine is unreferenced before retirement; unify clocks only after timezone/DST equivalence tests.

## Required validation before runtime consolidation

- Deterministic fixtures proving old and new outputs match for every preserved definition.
- Explicit tests for missing history, stale reference timestamps, equal-price ties, and no-lookahead behavior.
- D1, W1 and intraday timeframe separation tests.
- Regression tests for existing consumers and EA scoring.
- MetaEditor compilation and MT5 Strategy Tester validation after code changes. These have not been performed by this documentation-only audit.

## Non-goals and preserved components

Do not remove `LiquidityScoreEngine`, `PremiumDiscountEngine`, `DailyExtremeProjectionEngine`, `W1InstitutionalDirection`, `D1InstitutionalLevels`, or `AdvancedSessionORBEngine` merely because they share input data. Their purposes are distinct.

No IFVG, BPR or Unicorn module should be added until the existing FVG, structure, OB and reference-level contracts are consolidated and regression-tested.
