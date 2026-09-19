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
    AutopsyMacroFeeder.mq5             polls the bridge's /macro endpoint and writes the Ax_* yield GlobalVariables
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
| 2Y / 10Y / real yields | Alpha Vantage, via `server.js`'s `/macro` + `AutopsyMacroFeeder.mq5` — see below | that leg of the macro score is dropped, not faked |
| Fed expectations | **no genuine source found** — deliberately left unfed | that leg of the macro score is dropped |
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

**Yields are wired up.** `server/server.js` now exposes `GET /macro`, which
pulls `TREASURY_YIELD` (2year, 10year) and `CPI` from Alpha Vantage,
computes a real-yield proxy (10Y nominal minus trailing-12-month CPI
inflation — not TIPS breakeven, documented as an approximation in the
server code), and caches the result for 6 hours (a free Alpha Vantage key
is 25 requests/day total). `mt5/Experts/AutopsyMacroFeeder.mq5` is a small
script that runs alongside your EA, polls that endpoint every `PollMinutes`
(default 360) via `WebRequest`, and writes the five `Ax_US02Y_*` /
`Ax_US10Y_*` / `Ax_RealYield10Y_*` / `Ax_Macro_LastUpdateUnix` variables
above straight into the terminal. Set `ALPHAVANTAGE_API_KEY` in the
bridge's `.env`, run the bridge, add its URL under **Tools → Options →
Expert Advisors → Allow WebRequest for listed URL**, then attach the
feeder script once per terminal/account.

**Fed expectations and breadth are still deliberately unfed.** Alpha
Vantage has no market-implied Fed-funds-futures series and no
advance/decline or breadth series, and relabeling something else (e.g. the
realized Fed funds rate, which is backward-looking) as if it were either of
those forward-looking measures would be a mislabeling, not a fix. Both
`GlobalVariable`s stay unset; the macro and regime engines already treat an
unset variable as "unavailable" and degrade gracefully rather than
guessing, exactly as designed.

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
- **No live breadth feed, and no genuine Fed-expectations feed.** See above —
  yields now have a real feeder (`AutopsyMacroFeeder.mq5` + Alpha Vantage);
  breadth and Fed expectations remain intentionally unfed, since no honest
  source for either was found.

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
