# AUTOPSY X FLIPDEMON X15

Adaptive high-conviction account-growth and capital-survival Expert Advisor
for MetaTrader 5.

This is not a guaranteed-profit system, a martingale, or a grid-recovery bot.
It is a risk governor with a trade-idea generator attached: every entry has
to clear a fifteen-rung decision hierarchy (`EvaluateSymbol()` in the main
`.mq5` file) before it is allowed to risk a cent, and several independent
mechanisms exist purely to cut exposure or stop trading outright when the
evidence turns against it.

## Layout

```
AUTOPSY_X_FLIPDEMON_X15.mq5   orchestration + state machine + decision hierarchy
Common/   Defines.mqh          shared enums/structs/hard safety constants
          Inputs.mqh           every configurable threshold
Core/     MarketEngine, VolatilityEngine, RegimeEngine,
          StructureEngine, LiquidityEngine
Intelligence/ BiasEngine, ProbabilityEngine, OpportunityEngine,
              ExpectedValue, CorrelationEngine
Risk/     RiskEngine, CompoundingEngine, RuinEngine,
          DrawdownEngine, ExposureEngine
Execution/ BrokerAdapter, ExecutionEngine, PositionManager
Autopsy/  TradeJournal, DiagnosticEngine, DriftEngine
UI/       Dashboard
```

## Installing

1. Copy the `AUTOPSY_X_FLIPDEMON_X15` folder into your terminal's
   `MQL5/Experts/` directory (keep the subfolders — the `#include` paths are
   relative to the `.mq5` file).
2. Open `AUTOPSY_X_FLIPDEMON_X15.mq5` in MetaEditor and compile
   (F7). **This repository was built without access to a MetaEditor/MQL5
   compiler** — every file was written and manually cross-checked for
   correct MQL5 syntax, class/struct field names, and call signatures, but
   it has not been machine-compiled. Expect to run the compile → fix →
   compile loop described in the original spec's Section 50 at least once.
   Report any compiler errors and they can be fixed directly.
3. Attach to a chart. `Inp_LiveTradingEnabled` defaults to `false` — the EA
   will run its full analysis loop, log every decision, and update the
   dashboard, but will not send a single order until you explicitly set
   this to `true`. Test in Strategy Tester and/or on a demo account first.
4. Set `Inp_TradedSymbols` to the symbols your broker actually lists (the
   EA silently skips any symbol `SymbolSelect` can't find, and logs it).

## Key safety properties (verify these before going live)

- **Hard ceilings live in `Common/Defines.mqh`**
  (`AXF_HARD_MAX_RISK_PCT`, `AXF_HARD_MAX_PORTFOLIO_RISK`,
  `AXF_HARD_MAX_RISK_MULT`) and are the last clamp applied in
  `RiskEngine::ComputeFinalRiskPct` — no input combination or multiplier
  chain can exceed them.
- **No martingale / no loss-doubling**: `PositionManager::CanPyramid`
  refuses to add to a position unless it is *already profitable*
  (`PositionGetDouble(POSITION_PROFIT) > 0`) and a fresh A+ opportunity
  confirms in the same direction. There is no code path anywhere in this
  project that increases size after a loss.
- **The account-max-drawdown halt requires a human.** Once
  `DrawdownEngine::CheckAccountMaxDrawdown` latches, it is persisted to a
  `GlobalVariable` and stays latched — including across a terminal restart
  — until the chart's "RESET ACCOUNT HALT" button is clicked.
- **Every ruin/drawdown-probability number is labelled a model estimate**
  (`SAxfRuinEstimate.model_estimate` is always `true`) and is never
  presented as certainty, per the spec's requirement.
- **No fabricated intelligence**: macro/DXY correlation
  (`BiasEngine::MacroAlignment`) and the news calendar
  (`IsNewsBlackout` in the main file) both return "not checked" rather
  than a fabricated neutral/false reading when the underlying data source
  (a configured DXY symbol, the terminal's economic calendar) isn't
  available.

## What this build is honest about

See `docs/FINAL_AUDIT.md` for the full Section 51 audit, including the
things a from-scratch MQL5 EA cannot honestly claim without a compiler, a
broker connection, and a backtest — most importantly: **this system has
not been backtested, forward-tested, or optimized.** Positive expectancy is
a hypothesis this code is instrumented to measure (via its own trade
journal and `ProbabilityEngine`'s sample-size discounting), not a fact it
starts out knowing.

## Optional: web dashboard bridge

This repository already contains a small Node bridge (`/server`) and a web
dashboard (`/index.html`) with `/ingest/tick` and `/ingest/account`
endpoints. Setting `Inp_BridgeEnabled=true` and `Inp_BridgeURL` to that
server's address makes the EA POST account snapshots to it (you must also
allow the URL under *Tools → Options → Expert Advisors → Allow WebRequest
for listed URL*). This is telemetry only — the bridge cannot send orders
back to the EA.
