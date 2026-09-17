# AUTOPSY X — QQQ/TQQQ Regime Engine

A modular MQL5 intelligence layer you attach to an **existing** MT5 EA
without touching its entry, exit, stop-loss, trailing, or trade-management
logic. It answers one question — *can this bot trade right now, in which
direction, and how large* — and nothing else. It never places an order.

```
YOUR EA's SIGNAL  --request-->  AUTOPSY X  --permission-->  YOUR EA's EXECUTION
                                (unchanged)                  (unchanged)
```

TQQQ's 3× objective is daily and path-dependent, so this engine never
multiplies position size by 3 as a policy. Leverage is a conditional risk
state — the product of several independent multipliers — not a permanent
one.

## Install

Copy `mt5/MQL5/` into your terminal's data folder (File → Open Data
Folder in MetaTrader 5), merging it with the existing `MQL5/` directory so
you end up with:

```
MQL5/Include/AutopsyX/*.mqh
MQL5/Experts/AutopsyX/AutopsyX_Example_EA.mq5
```

Then in MetaEditor: `#include <AutopsyX/AutopsyX.mqh>` in your own EA (see
`AutopsyX_Example_EA.mq5` for a full wiring example), and compile.

**This repository was built and reviewed without access to MetaEditor or
the MQL5 compiler** — there's no Windows MT5 toolchain in this
environment. The code has been written and re-read carefully for MQL5
syntax correctness, but compile it yourself before trusting it with a
real account, exactly as you would with any code from any source.

## Architecture

| File | Spec section | Responsibility |
|---|---|---|
| `AutopsyTypes.mqh` | — | Shared enums/structs — no logic |
| `AutopsyVolatilityEngine.mqh` | 6, 7 | ATR/ATR percentile, realized vol, VIX, LOW→EXTREME classification, R6 shock detector |
| `AutopsyMacroEngine.mqh` | 8 | DXY/yield momentum, real-yield proxy, MACRO_SCORE |
| `AutopsyRegimeEngine.mqh` | 3, 4, 5, 9, 10, 11, 12 | Direction (EMA structure, HH/HL, breakout, momentum), trend efficiency, breadth, liquidity, composite confidence, R1–R6 decision matrix |
| `AutopsyRiskGovernor.mqh` | 13, 14, 20 | TQQQ leverage model (product of multipliers), drawdown governor, fail-safe clamps |
| `AutopsyCorrelationEngine.mqh` | 15 | Cross-EA aggregate Nasdaq exposure via `GlobalVariable_*` |
| `AutopsyEventFilter.mqh` | 16 | FOMC/CPI/PCE/NFP/GDP pre-event/blackout/wait-for-reprice |
| `AutopsyLogger.mqh` | 23 | One CSV row per decision |
| `AutopsyAlphaVantageBridge.mqh` | 8, 9 | Optional — pulls real Treasury yields, Fed funds momentum, CPI, and a breadth proxy from the bridge server's `/macro/snapshot` |
| `AutopsyX.mqh` | 2, 17, 19, 21, 22 | Facade — the only file your EA needs to include |

`AutopsyX_Example_EA.mq5` shows the full call sequence. It deliberately
stops short of a real `OrderSend` — the `TODO` inside `OnApprovedSignal()`
marks exactly where your EA's existing execution code goes, unchanged.

## What this honestly can and can't source

MT5 has no native feed for market breadth, "real yields," or Fed
expectations, and VIX/DXY/2Y/10Y availability depends entirely on your
broker's symbol list. Rather than fabricate these, every engine here
degrades explicitly instead of guessing:

- **Breadth** (`SetBreadthInputs()` global wrapper) is a pluggable
  external feed. Until something calls it — the Alpha Vantage bridge
  below, a script, or your own feed — breadth reads neutral (0) and its
  weight in the composite confidence contributes nothing; it does not
  fake a bullish or bearish tilt.
- **VIX/DXY/2Y/10Y** are optional config strings. Leave any blank, or
  point it at a symbol your broker doesn't actually list, and that leg is
  dropped from the macro/volatility score with `DATA_STATUS = DEGRADED`
  logged — never silently treated as calm or bullish (spec section 20).
  (2Y/10Y have a second path now — see below.)
- **Real yields / Fed expectations**: without the Alpha Vantage bridge,
  these are built from 2Y/10Y *momentum* on whatever CFD symbols your
  broker lists (if any), plus a manual inflation-expectation input for
  the real-yield proxy — a documented approximation, not a
  market-sourced number. **With** the bridge, `AutopsyMacroEngine.mqh`
  prefers real Treasury yield data and an actual CPI YoY print over
  both of those (see below); either way, treat `GetMacroScore()` as a
  directional read, not a precise print.
- **Economic calendar** (`AutopsyEventFilter.mqh`) tries MT5's
  `CalendarValueHistory`/`CalendarEventById` first; not every broker
  server feeds it. `AddManualEvent()` is the reliable baseline — schedule
  FOMC/CPI/NFP/etc. by hand and the live calendar becomes a bonus layered
  on top, not the only source.
- **Correlation protection** only sees exposure reported (via
  `ReportOwnExposure()`) by other AutopsyX instances on the **same MT5
  terminal**. It cannot see positions in a different terminal or account.

## Alpha Vantage macro/breadth data (optional)

MT5 can't source real Treasury yields, Fed funds momentum, actual CPI, or
any breadth data on its own. `AutopsyAlphaVantageBridge.mqh` closes part of
that gap by pulling it from Alpha Vantage — through the same Node bridge
server this repo already ships for the dashboard (`server/server.js`), not
by calling Alpha Vantage directly from MT5. Two reasons for the extra hop:
the API key stays server-side instead of living in an MT5 input field, and
Alpha Vantage's free tier is 25 requests/day — the bridge caches every
series for hours so polling it from MT5 costs cache hits, not quota.

Setup:

1. In `server/.env`, set `ALPHA_VANTAGE_API_KEY` (free at
   [alphavantage.co/support/#api-key](https://www.alphavantage.co/support/#api-key))
   alongside your existing `BRIDGE_KEY`. Restart `npm start`.
2. In MT5: **Tools → Options → Expert Advisors → Allow WebRequest for
   listed URL**, and add your bridge's URL (e.g.
   `http://127.0.0.1:8787`, or your Render URL). Without this,
   `WebRequest()` always fails with error 4060 — `AutopsyAlphaVantageBridge.mqh`
   prints exactly that guidance when it happens.
3. In your EA (or `AutopsyX_Example_EA.mq5`'s `InpAvBridgeUrl`/
   `InpAvBridgeKey` inputs), set `AxConfig.av_bridge_url` and
   `av_bridge_key`, then call `RefreshFromAlphaVantageBridge()`
   periodically — once every H1–D1 bar is plenty, since the underlying
   data itself only updates a few times a day. It's a blocking network
   call, so never call it every tick.

What it actually feeds, and what it doesn't:

- `us10y_level` / `us10y_momentum_bps_10d`, `us2y_momentum_bps_10d`,
  `fed_funds_momentum_bps_30d`, `cpi_yoy_pct` — real data, preferred over
  the CFD-symbol path in `AutopsyMacroEngine.mqh` whenever it's fresh
  (`AxMacroThresholds.external_stale_minutes`, default 3 hours). The
  real-yield calculation switches from the manual inflation-expectation
  input to an actual CPI YoY print the moment this is fed.
- `breadth_advancers`/`breadth_decliners` — fed into the same
  `SetBreadthInputs()` slot as any other breadth source, but it is
  **not** true market-wide advance/decline breadth. Alpha Vantage has no
  such endpoint; this counts gainers vs. decliners among its top-20
  most-actively-traded list, a narrow participation proxy. `pct_above_50ma`
  and `semis_participation` get passed as neutral (50) alongside it —
  Alpha Vantage doesn't cover those either, and this call doesn't
  silently preserve whatever real values you may have fed there before.
- **DXY has no path here at all.** Alpha Vantage doesn't publish a
  dollar index; DXY still only comes from a broker CFD symbol, or stays
  degraded.
- `news_sentiment_score` is fetched and parsed but not currently wired
  into any score — `CAxAlphaVantageBridge::Fetch()` returns it on the
  snapshot struct if you want to use it for your own logic.

## Minimal integration

```mql5
#include <AutopsyX/AutopsyX.mqh>

int OnInit()
  {
   AxConfig cfg; cfg.Defaults();
   cfg.symbol_price = "QQQ";           // or your broker's US100/NAS100 CFD
   cfg.bot_id        = "MyExistingEA";
   cfg.base_risk_pct = 1.0;
   return InitializeRegimeEngine(cfg) ? INIT_SUCCEEDED : INIT_FAILED;
  }

void OnTick()
  {
   if(!UpdateMarketState() || !AllowNewTrade()) return;

   bool mySignalIsLong = /* your existing EA's own logic, untouched */;
   if(mySignalIsLong && AllowLong())
     {
      double lots = MyExistingLotSizing() * GetRiskMultiplier(); // scale, don't replace, your sizing
      // your existing OrderSend()/CTrade call goes here, unchanged
     }
  }
```

## Validating it (spec section 24)

The engine is not considered validated on in-sample profit alone. After
running it in MT5's Strategy Tester (or forward-testing on a demo):

1. Export the trade history (Terminal "History" tab → Save as Report, or
   the Strategy Tester report) to CSV.
2. Pull the decision log AutopsyLogger wrote (`MQL5/Files/AutopsyX_Log.csv`
   by default, or `AutopsyX_<bot_id>_Log.csv` from the example EA).
3. Run:

   ```
   python3 tools/autopsyx_backtest_stats.py \
     --decision-log AutopsyX_Log.csv \
     --trades mt5_trade_history.csv \
     --balance 10000 \
     --out autopsyx_backtest_report.md
   ```

This computes net return, max drawdown, profit factor, Sharpe, Sortino,
Calmar, win rate, average trade, tail loss, worst day/week,
volatility-adjusted return, and time in market — broken out overall, by
long vs short, by regime, and by whether a volatility shock was active —
matching the section 24 checklist. It does not run walk-forward or Monte
Carlo analysis for you; re-run it across separate in-sample,
out-of-sample, and walk-forward windows (different date ranges through
the Strategy Tester) and compare the reports, rather than trusting one
in-sample run. Requires `pandas` and `numpy` (`pip install pandas numpy`).
