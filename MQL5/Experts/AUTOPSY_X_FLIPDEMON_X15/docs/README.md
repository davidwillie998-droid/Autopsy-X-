# AUTOPSY X FLIPDEMON X15

Adaptive high-conviction account-growth and capital-survival Expert Advisor
for MetaTrader 5.

This is not a guaranteed-profit system, a martingale, or a grid-recovery bot.
It is a risk governor with a trade-idea generator attached: every entry has
to clear a fifteen-rung decision hierarchy (`EvaluateSymbol()` in the main
`.mq5` file) before it is allowed to risk a cent, and several independent
mechanisms exist purely to cut exposure or stop trading outright when the
evidence turns against it.

Rungs 10-14 of that hierarchy — probability, expected value, risk-of-ruin,
flip score, adaptive capital state, dynamic risk, portfolio exposure,
position sizing — are consolidated behind one modular, account-agnostic
unit, `Risk/AdaptiveFlipEngine.mqh`. See **The Adaptive Flip Engine**
section below for what that means and the one behavior fix that came with
consolidating it.

## Layout

```
AUTOPSY_X_FLIPDEMON_X15.mq5   orchestration + state machine + decision hierarchy
Common/   Defines.mqh          shared enums/structs/hard safety constants
          Inputs.mqh           every configurable threshold
Core/     MarketEngine, VolatilityEngine, RegimeEngine,
          StructureEngine, LiquidityEngine, OrderFlowEngine
Intelligence/ BiasEngine, ProbabilityEngine, OpportunityEngine,
              ExpectedValue, CorrelationEngine
Risk/     AdaptiveFlipEngine (consolidates Probability/ExpectedValue/
          Diagnostic/Risk/Exposure), RiskEngine, CompoundingEngine,
          RuinEngine, DrawdownEngine, ExposureEngine
Execution/ BrokerAdapter, ExecutionEngine, PositionManager
Autopsy/  TradeJournal, DiagnosticEngine, DriftEngine
UI/       Dashboard, OrderFlowPanel
```

## The Adaptive Flip Engine

`Risk/AdaptiveFlipEngine.mqh` (`CAxfAdaptiveFlipEngine`) is the single,
modular entry point for the "flip" decision: it owns `ProbabilityEngine`,
`ExpectedValue`, `DiagnosticEngine` (the Flip Score), `RiskEngine`, and
`ExposureEngine` internally and sequences them — probability → expected
value → risk-of-ruin → order-flow confirmation → flip score → adaptive
capital state → dynamic risk → portfolio exposure → position size — behind
one `Evaluate()` call that returns an `SAxfFlipDecision`. `main.mq5`'s
`EvaluateSymbol()` now calls this once instead of manipulating five
separate global engines inline.

**This was a consolidation, not a rewrite.** Every formula, threshold, and
rejection order inside it is identical to what previously lived inline in
`EvaluateSymbol` — an architectural audit confirmed the underlying math was
already sound and just needed to be one addressable, testable unit instead
of ~80 lines of procedural code. Pyramiding adds and the dashboard's
portfolio-risk readout now go through the same engine's `ComputeLots()`/
`CanAcceptNewRisk()`/`CurrentEffectiveRisk()` pass-throughs, instead of a
second, independent call path to the same math.

**Account-agnostic by construction**: every value this engine touches is a
percentage, an R-multiple, or a broker-reported per-unit value (tick
value/size) passed in by the caller. It never reads `AccountInfo*` or any
other single-account assumption directly, so the identical engine instance
is correct whether the account behind it holds $500 or $5,000,000, in any
currency.

**Hard safety limits are not re-implemented here.** `AXF_HARD_MAX_RISK_PCT`
and friends (`Common/Defines.mqh`) remain the final clamp inside
`RiskEngine::ComputeFinalRiskPct` — this engine calls that same function
and has no separate risk-calculation path that could bypass it.

**The one real behavior fix that came out of the audit**: `DriftEngine`
(edge-decay detection) previously computed a recommendation every cycle
and only ever printed it — `DRIFT_REDUCE_RISK` didn't reduce risk,
`DRIFT_HALT_RECOMMENDED` didn't halt anything. "Loss and edge-decay
protection" isn't real if the decay signal is just a log line, so
`AdaptiveFlipEngine::Evaluate()` now actually applies it:
`DRIFT_HALT_RECOMMENDED` rejects the trade outright (toggle with
`Inp_Drift_HaltOnRecommendation`), and `DRIFT_REDUCE_RISK` multiplies the
final risk% by `Inp_Drift_ReduceFactor` (default 0.5) — on top of, never
bypassing, the hard risk ceiling. `Inp_Drift_RecentTrades`/
`Inp_Drift_BaselineTrades` (previously hardcoded 20/60) are now
configurable inputs too.

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

## Sniper entries (the priority feature)

`Inp_SniperEntryMode` defaults to `true`. With it on, the EA never chases a
breakout with a market order. Instead, `OpportunityEngine::Build` locates
the order block (or, failing that, the Fair Value Gap) that produced the
break of structure, prices a precise retracement point inside it
(`Inp_SniperZoneFraction` controls how deep — 0 is the near edge that fills
easily at a worse price, 1 is the far edge that fills rarely at the best
price), and validates that the zone is a genuine, reachable retracement:
on the correct side of both the current price and the stop, not farther
than `Inp_SniperMaxDistanceATR` away, and not so close it isn't really a
retracement (`Inp_SniperMinDistancePoints`).

When a valid zone exists, the EA places a pending `BuyLimit`/`SellLimit`
there (`ExecutionEngine::PlacePendingLimit`) and waits — up to
`Inp_SniperExpiryMinutes`, or until a fresh CHOCH invalidates the setup
before it ever fills (`Inp_SniperCancelOnInvalidation`), whichever comes
first (`ManagePendingSniperOrders` in the main file). **When no honest zone
exists, sniper mode rejects the setup outright rather than falling back to
a market chase** — that's the entire point of prioritizing this over trade
frequency. Set `Inp_SniperEntryMode=false` to restore the old
immediate-market-entry behavior as a fallback for setups with no zone,
instead of skipping them.

A filled sniper order is picked up in `OnTradeTransaction` (matched by the
originating order ticket) and migrated into the same live-position
management path as a market entry — trailing, partials, and thesis-
invalidation exits all work identically regardless of how the position was
opened. Pyramiding adds, by contrast, always execute at market (continuation
on strength isn't a retracement wait) and size themselves off the live
market price, not off any zone `Build()` may have computed for a fresh entry.

## Live execution realism (demo ≠ live)

A demo account's spread and slippage are not a reliable stand-in for a real
one, so several mechanisms judge live conditions against what THIS account
actually shows, not a fixed assumption from a backtest or a demo session:

- **Spread**: `BrokerAdapter::PreTradeCheck` rejects on an absolute ceiling
  (`Inp_MaxSpreadPoints`) *and* on a relative blowout — current spread more
  than `Inp_SpreadAnomalyMultiple`× this symbol's own rolling median
  (`MarketEngine::MedianSpreadPoints`, fed once per timer cycle, needs
  `Inp_MinSpreadSamplesToJudge` samples before it's trusted).
- **Rollover**: `Inp_RolloverBlackoutEnabled` blocks new entries within
  `Inp_RolloverBlackoutMins` minutes of `Inp_RolloverHourServer` — check
  your broker's actual rollover time, it varies.
- **Slippage**: `ExecutionEngine` tracks realized per-symbol slippage from
  every real fill; once `Inp_MinSlippageSamplesToUse` fills exist, the
  Expected Value engine uses that realized average instead of the static
  `Inp_AssumedSlippagePoints` guess — and `AvgSlippagePoints` never lets a
  live-observed number undercut the conservative floor, only widen it.

None of this substitutes for actually running the EA on the live account
it will trade — broker-specific execution quality, requote behavior, and
fill policy vary too much to fully anticipate from code alone.

## Order flow / microstructure edition

`Core/OrderFlowEngine.mqh` adds Volume Profile (POC/VAH/VAL), Cumulative
Delta, a fast "Pulse" pressure oscillator, footprint-lite stacked-imbalance
detection, and a DOM/heatmap read. **Read this before trusting any of it —
it is not exchange-grade order flow:**

- **Volume Profile is real** regardless of broker: it bins tick/quote
  activity by price over `Inp_OrderFlowTickLookbackMinutes` and finds the
  POC and the `Inp_ValueAreaPct`% value area around it.
- **Cumulative Delta, Pulse, and Footprint use the tick rule** (price up =
  buy-side, price down = sell-side, unchanged = inherit the prior side)
  *unless* an individual tick carries a real `TICK_FLAG_BUY`/`TICK_FLAG_SELL`
  flag, in which case that real flag is used directly.
  `SAxfOrderFlow.ticks_are_real_trades` tells you which one you actually
  got for a given read — most retail FX/CFD feeds will show `false`
  (tick-rule approximation) because the broker hands the terminal quote
  ticks, not an aggressor-tagged trade tape.
- **Footprint here means a per-bar buy/sell delta with stacked-imbalance
  detection** (`Inp_FootprintBarsLookback` bars, `Inp_FootprintImbalanceRatio`
  threshold) — not a rendered price-ladder footprint chart. That's a
  charting feature; this is the summary signal that actually feeds the
  Flip Score.
- **DOM/heatmap needs the broker to expose Level 2 depth**
  (`MarketBookAdd` returning `true` for the symbol). Most FX symbols on
  most retail brokers do not support this. When unsupported, every DOM
  field reads as unavailable — it never fabricates a heatmap.

By default this is informational: it contributes up to 6 of the Flip
Score's 100 points (`DiagnosticEngine`) and nothing else. Set
`Inp_OrderFlowConfirmationRequired=true` to make it a hard gate — a sniper
entry is refused if the Pulse opposes the trade direction beyond
`Inp_OrderFlowConfirmPulseMin` — but only turn this on once you've checked
`ticks_are_real_trades` and the DOM availability line on the dashboard for
your actual broker/symbol; gating real money on a tick-rule approximation
with thin history is worse than not gating at all.

Tick fetching is throttled per symbol (`Inp_OrderFlowRecalcSeconds`,
default 10s) and capped (`Inp_OrderFlowMaxTicks`) — it is not free, and is
not run on every timer tick.

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
