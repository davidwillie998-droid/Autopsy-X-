# AUTOPSY X - QQQ/TQQQ Regime Engine

A standalone MQL5 include library: a modular intelligence/risk-governor layer that attaches to an **existing** trading bot without replacing its entry, execution, stop-loss, trailing, or trade-management logic. It answers five questions - what regime is Nasdaq in, is the environment bullish/bearish/neutral, is the trend efficient enough for aggressive exposure, is volatility expanding or contracting, and should the existing bot operate normally, reduce risk, or stand down - and exposes the answer as a simple permission API. It never places an order itself.

This is a different, independent deliverable from `AUTOPSY_X_SWINGDEMON_X15` elsewhere in this repo. It shares the AUTOPSY X name and some conventions (GlobalVariable-backed persistence, append-only CSV audit logs, honest degradation on missing data) but has no code dependency on that EA and is designed to be portable across *any* existing bot.

## What this honestly is (and is not)

Built and reviewed line-by-line for MQL5 correctness with no MetaEditor/MetaTrader available in this environment - **it has not been compiled or strategy-tested.** Treat first compilation as the start of validation (section 24's own backtest requirement - in-sample, out-of-sample, walk-forward, Monte Carlo, parameter sensitivity - applies here before any live use), not the end of it.

MT5 has no native feed for several inputs the original spec lists. Every one of them is handled the same honest way used throughout this repo: compute it for real when the data is genuinely available, and degrade cleanly to neutral/zero-reliability - never fabricate a number - when it isn't.

- **Real yields, Fed-funds/OIS-implied expectations, and the official Nasdaq advance/decline line have no MT5 data source at all.** Fed expectations always contribute zero to `MACRO_SCORE` (there is nowhere honest to source this from inside MT5). Real yields are an optional configurable proxy symbol (`InpRealYieldSymbol`) - if your broker offers one and you wire it in, it's used for real; otherwise it contributes zero, not a guess.
- **DXY / 2Y / 10Y yields** are optional configurable proxy symbols (whatever CFD/index your broker actually lists). Left blank, or unresolvable, they drop out of `MACRO_SCORE`'s weighting entirely rather than being invented - `macroReliability` in the output reports what fraction of the configured weight was actually backed by real data.
- **Breadth** has no official constituent feed. `AutopsyBreadthLiquidityEngine` computes a REAL breadth proxy from a basket of symbols *you* configure (`InpBreadthBasket`, e.g. a comma-separated list of large-cap/semiconductor names your broker offers as CFDs/stocks) - % of that basket trading above its own 50-day MA. An empty basket degrades to zero reliability. This is a genuine measurement of whatever basket you give it, not the official Nasdaq breadth series - don't mistake the two.
- **The one non-proxied, always-real macro input** is the MT5 Economic Calendar's own actual-vs-forecast values (`CalendarValueHistory`/`CalendarEventById`) for a curated set of high-impact USD releases (CPI, PCE, Non-Farm Payrolls, GDP, Fed Funds/Interest Rate decisions). The surprise-direction sign convention (a CPI beat is bearish for risk assets, a GDP beat is bullish, a payrolls beat is damped/ambiguous) is a documented simplification of genuinely context-dependent market reactions - see the comments in `AutopsyMacroEngine.mqh`.

## Architecture

```
AutopsyTypes.mqh                  - shared enums/structs, AXRConfig (every tunable in one place), AXRPermission (the output)
AutopsyDirectionEngine.mqh        - EMA20/50/200 structure, fractal HH/HL vs LH/LL, N-day breakout/breakdown, momentum -> DIRECTION_SCORE
AutopsyVolatilityEngine.mqh       - ATR percentile, true realized-volatility percentile, optional VIX proxy -> VOLATILITY_SCORE/state, R6 shock detector
AutopsyMacroEngine.mqh            - DXY/yield/real-yield proxies + real economic-calendar surprise -> MACRO_SCORE (confirmation-only, never inverts direction)
AutopsyBreadthLiquidityEngine.mqh - configurable-basket breadth proxy + QQQ relative-volume/participation -> BREADTH_SCORE, LIQUIDITY_SCORE
AutopsyCorrelationEngine.mqh      - scans EVERY open position, any magic number, for Nasdaq-correlated symbols -> AGGREGATE_NASDAQ_EXPOSURE
AutopsyEventFilter.mqh            - real MT5 Economic Calendar governor: PRE_EVENT_MODE / in-event block / post-event WAIT_FOR_REPRICE
AutopsyRiskGovernor.mqh           - the leverage model (never position_size x 3) + banded drawdown governor with a halt/reset
AutopsyLogger.mqh                 - per-decision audit trail (Print + append-only CSV), section 23's format
AutopsyRegimeEngine.mqh           - the ONLY file an existing EA needs to include: orchestrates everything above, R1-R6 classification, composite confidence, the public permission API
```

`AUTOPSY_X_REGIME_DEMO.mq5` (in `MQL5/Experts/`) is a minimal reference EA showing the integration pattern - it is not meant to be run live unmodified (`InpEnableLiveTrading` defaults to `false`).

## Regime classification (sections 3/12)

Six states: **R1** persistent bullish, **R2** bullish-but-unstable, **R3** range/chop, **R4** bearish transition, **R5** persistent bearish, **R6** volatility shock. `AutopsyRegimeEngine::ClassifyRegime()` codifies the spec's qualitative "requirements" list into a deterministic decision tree driven entirely by `AXRConfig` thresholds (direction strength, trend-efficiency bands, volatility state, macro/breadth conflict checks) - nothing is hard-coded permanently, every threshold is a config field with a documented default.

One deliberate, documented deviation from a literal reading of section 12: R5 (persistent bearish) lists "breadth weak" as a hard requirement alongside direction/efficiency/volatility. Since breadth is the least-often-configured input here (no native feed, optional basket), a strict AND would make R5 nearly unreachable whenever breadth is left unconfigured - which is the common case. Breadth is instead treated as a **confirming co-factor**: it can *demote* R1/R5 to R2/R4 when it actively *disagrees* with the classified direction (a real, configured basket showing genuine narrow/unhealthy participation), but its absence or unreliability is never treated as either a block or a free pass, consistent with section 20's "never treat missing data as bullish confirmation" - extended here to mean missing data is never treated as ANY kind of confirmation, bearish included.

## The leverage model (section 13) - never `position_size x 3`

```
FINAL_RISK% = BASE_RISK% x REGIME_MULT x CONFIDENCE_MULT x VOLATILITY_MULT x CORRELATION_MULT x DRAWDOWN_MULT
```

Every multiplier is clamped to a sane band before composing (`AutopsyRiskGovernor::ComposeFinalRiskPercent`) so a single mis-behaving component can't blow out the formula. `AXRPermission` exposes both forms: `riskMultiplier` (section 18's style, e.g. `1.25`) and `finalRiskPercent` (section 13's style, an absolute account-equity percentage) - use whichever your existing bot's own position-sizing code expects.

The drawdown governor (section 14) measures drawdown from a persistent **peak-equity high-water mark** (global variables, survives restarts), applies the configured banded multiplier, and **halts outright** past the last band - a halt is never auto-cleared by equity recovering on its own; call `ResetRiskGovernor()` deliberately.

## Correlation governor (section 15)

`AutopsyCorrelationEngine` scans **every open position on the account, across every magic number** - not just the bot this engine is attached to - for symbols in a configurable Nasdaq-correlated list (`"QQQ,TQQQ:3.0,US100:1.0,NAS100:1.0"` syntax: `SYMBOL:beta`, beta defaults to 1.0). This is exactly what section 15 asks for: several bots trading QQQ/TQQQ/NQ/MNQ/US100/tech names simultaneously are seen as one synthetic Nasdaq position, not several independent ones, and new trades reduce/block once the configured aggregate-exposure limit is exceeded.

## Event governor (section 16)

Real MT5 Economic Calendar data, not a guess. Three states around any curated high-impact USD release (FOMC/CPI/PCE/NFP/GDP/Fed speeches): `PRE_EVENT_MODE` (risk capped, configurable multiplier), an in-event hard block (`allowNewTrade=false`), and a post-event `WAIT_FOR_REPRICE` window before the regime is trusted again - the initial post-release spike is never assumed to be the final direction.

## Fail-safe (section 20)

`AXRPermission.dataStatus` is `OK`, `DEGRADED`, or `CRITICAL`. `CRITICAL` (the reference symbol's own EMA/ATR data is unavailable - the classifier cannot honestly run at all) blocks new trades outright. `DEGRADED` (any optional input - macro, breadth, VIX, liquidity - missing or unreliable) caps the risk multiplier at 0.25x; it never raises it. Missing data is never interpreted as bullish OR bearish confirmation, in either direction.

## Using it from an existing bot

```mql5
#include <AutopsyX/AutopsyRegimeEngine.mqh>

CAutopsyRegimeEngine g_engine;

int OnInit()
  {
   AXRConfig cfg = AXRDefaultConfig("MyBot_"+_Symbol, _Symbol); // idPrefix, referenceSymbol
   cfg.breadthBasketCsv = "AAPL,MSFT,NVDA,GOOGL,AMZN,META";     // optional - override only what you need
   g_engine.Init(cfg);
   return(INIT_SUCCEEDED);
  }

void OnTick()
  {
   g_engine.UpdateMarketState();               // throttles the expensive classification to once/bar internally
   if(!g_engine.AllowNewTrade()) return;        // "can I trade?"
   int myDirection = MyOwnStrategySignal();     // your existing bot's own signal, untouched
   if(myDirection>0 && !g_engine.AllowLong())  return;
   if(myDirection<0 && !g_engine.AllowShort()) return;
   double riskPct = g_engine.GetFinalRiskPercent(); // "what risk multiplier?" - feed into YOUR sizing
   // ... your existing bot's own execution, unchanged ...
   g_engine.LogDecision("APPROVE");
  }
```

`AUTOPSY_X_REGIME_DEMO.mq5` is the fuller version of this pattern, including risk-scaled position sizing and the FLIPDEMON-compatibility hierarchy from section 19 (`SAFETY > REGIME > RISK > STRATEGY > ENTRY > EXECUTION`).

## Configuration

Everything tunable lives in one `AXRConfig` struct (`AutopsyTypes.mqh`), built via `AXRDefaultConfig(idPrefix, referenceSymbol)` and overridden field-by-field - direction-engine EMA/breakout/momentum periods, volatility percentile lookbacks and classification thresholds, shock-detector conditions and minimum simultaneous count, macro proxy symbols and calendar lookback, breadth basket and MA period, correlation list and exposure cap, event-filter windows, drawdown bands, and the composite-confidence weights (direction/trend-efficiency/volatility/macro/breadth/liquidity - defaults 30/20/20/15/10/5, matching section 11, but never hard-coded).

## Data persistence

- **Drawdown governor peak-equity and halt state**: global variables (`AXR_RISKGOV_<idPrefix>_*`) - survives terminal restarts, and a halt stays latched until `ResetRiskGovernor()` runs.
- **Decision audit trail**: `AutopsyX_RegimeLog_<idPrefix>.csv` in the terminal's `MQL5/Files` folder, append-only, one row per `LogDecision()` call.
