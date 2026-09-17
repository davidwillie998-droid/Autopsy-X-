# AUTOPSY X — QQQ/TQQQ Regime Engine (MT5 module)

A modular intelligence/risk-governor layer for an *existing* MT5 Expert
Advisor. It never places, modifies, or closes an order. It only answers
three questions for whatever EA includes it: **can I trade, which side, and
at what size** — see `AutopsyRegimeEngineCore.mqh` for the exact API.

```
FLIPDEMON / YOUR EA  ->  REQUEST TRADE
        ↓
  REGIME ENGINE  ->  RISK GOVERNOR  ->  PERMISSION
        ↓
  YOUR EA EXECUTES NORMALLY
```

## Layout

```
mt5/
  Include/AutopsyX/
    AutopsyXCommon.mqh            shared enums, structs, math helpers
    AutopsyVolatilityEngine.mqh   ATR/realized-vol/VIX, LOW..EXTREME, shock detector (R6)
    AutopsyMacroEngine.mqh        DXY + yields/Fed-expectations (see "Data gaps" below)
    AutopsyRegimeEngine.mqh       direction, trend-efficiency, breadth, liquidity, R1-R6 classifier, composite confidence
    AutopsyRiskGovernor.mqh       regime decision matrix, TQQQ leverage model, drawdown governor, fail-safe cap
    AutopsyCorrelationEngine.mqh  aggregate Nasdaq-equivalent exposure across every open position on the account
    AutopsyEventFilter.mqh        FOMC/CPI/PCE/NFP/GDP/Fed-speech blackout, via MT5's native Economic Calendar
    AutopsyRegimeEngineCore.mqh   top-level facade + the public API + section-23 decision logging
  Experts/
    AutopsyX_Example_Governor_EA.mq5   reference wiring — copy the *pattern*, not the (deliberately trivial) signal
```

Copy the whole `Include/AutopsyX/` folder into your terminal's
`MQL5/Include/AutopsyX/`, and `Experts/AutopsyX_Example_Governor_EA.mq5`
into `MQL5/Experts/` if you want to see it run before touching your own EA.

## Wiring it into your real EA

```cpp
#include <AutopsyX/AutopsyRegimeEngineCore.mqh>

int OnInit()
  {
   InitializeRegimeEngine("QQQ", PERIOD_D1, 1.0 /* base risk % */,
                           "VIX" /* or "" */, "DXY" /* or "" */);
   return(INIT_SUCCEEDED);
  }

void OnDeinit(const int reason) { ShutdownRegimeEngine(); }

void OnTick()
  {
   if(!IsNewBar()) return;          // your own new-bar check
   UpdateMarketState();

   bool wantLong  = YourSignal() == SIGNAL_LONG;   // your existing entry logic, untouched
   bool wantShort = YourSignal() == SIGNAL_SHORT;

   if(!AllowNewTrade()) return;
   double riskPct = GetFinalRiskPct();             // regime x confidence x vol x correlation x drawdown x event

   if(wantLong  && AllowLong())  YourOpenLong(riskPct);
   if(wantShort && AllowShort()) YourOpenShort(riskPct);
  }
```

`Matrix()`, `Volatility()`, `Macro()`, `Regime()`, `Correlation()`, `Events()`
and `Drawdown()` on the global engine object (`g_AxEngine` if you want the
class directly instead of the free-function wrappers) expose every
configurable knob mentioned in the spec — regime risk bands, EMA periods,
shock thresholds, confidence weights, drawdown brackets, the correlation
watchlist, event windows, all of it. Defaults match the spec's own numbers;
override what you disagree with in `OnInit()` before the first
`UpdateMarketState()` call.

## Required and optional symbols

| Feed | Where it comes from | If missing |
|---|---|---|
| QQQ/TQQQ price + volume | your broker's own symbol, required | engine can't initialize |
| VIX | a broker symbol, if offered | that leg of the volatility score is dropped, not faked |
| DXY / USD index | a broker symbol, if offered | that leg of the macro score is dropped |
| 2Y / 10Y / real yields, Fed expectations | **no MT5-native source exists** | GlobalVariable feed, see below |
| Breadth (advance/decline, % above MA) | **no MT5-native source exists** | GlobalVariable feed, see below |
| Economic calendar (FOMC/CPI/PCE/NFP/GDP) | MT5's built-in Economic Calendar | works out of the box if your broker/terminal syncs it |

### The data MT5 genuinely doesn't have

Treasury yields, real yields, Fed-funds-futures-implied expectations, and
market breadth statistics are not available as MT5 symbols on essentially
any retail broker. Rather than fabricate them from something else, these
engines read a small, documented set of `GlobalVariable`s that an external
process is responsible for keeping fresh:

```
Ax_US02Y_Level, Ax_US02Y_ChangeBps
Ax_US10Y_Level, Ax_US10Y_ChangeBps
Ax_RealYield10Y_Level, Ax_RealYield10Y_ChangeBps
Ax_FedExpectations_Score      (-100 dovish surprise .. +100 hawkish surprise)
Ax_Macro_LastUpdateUnix       (freshness timestamp — feeds older than 24h read as DEGRADED)

Ax_Breadth_Score               (-100 .. +100)
Ax_Breadth_LastUpdateUnix
```

This repo already runs a Node bridge (`server/server.js`) for the dashboard's
live MT5 panel — the natural next step is teaching it to pull yields
(Treasury/FRED), a Fed-expectations read, and a breadth stat, then push them
into the terminal as global variables (e.g. via a small MT5-side script that
polls an HTTP endpoint, or `GlobalVariableSet` from a companion indicator).
That bridge extension is **not built yet** — until something is writing
these variables, the corresponding score legs just degrade gracefully and
drop out of the composite, per the section-20 fail-safe rule (missing data
never gets treated as confirmation).

## What this build does *not* include

- **No compiler check.** This was written and reviewed carefully, but there
  is no MetaEditor/MQL5 compiler available in the environment this was
  built in. Open every file in MetaEditor and compile before doing anything
  else with it.
- **No backtest, walk-forward, or Monte Carlo run.** Spec section 24 is
  explicit that the engine "is not considered validated until its
  performance survives out-of-sample testing" — none of that testing has
  been run here; there's no historical data feed in this environment to run
  it against. Do that in the Strategy Tester, on your own account's actual
  symbol, before trusting this with real capital.
- **No live yields/breadth feed.** See above — those two inputs are wired
  and ready to receive data, but nothing is sending them yet.

## Design notes worth knowing

- Risk multipliers scale linearly across each regime's configured
  min/max band with composite confidence — a low-confidence R1 read sits
  near the band floor, not the ceiling, regardless of how "strongly
  bullish" the regime label sounds.
- The correlation engine sums **every open position on the account**, not
  just this EA's own trades — that's the only way to catch several bots
  stacking one synthetic Nasdaq position, but it also means it's blind to
  positions on a different account entirely.
- The section-20 fail-safe cap only fires on the data sources the spec
  explicitly names (DXY, VIX, the QQQ/TQQQ price feed itself, the macro
  feed as a whole). Breadth has no MT5-native source at all, so it's
  designed to degrade gracefully via renormalized weighting instead —
  otherwise the engine would ship permanently capped at 0.25x for anyone
  who hasn't wired an external breadth feed, which defeats the point.
