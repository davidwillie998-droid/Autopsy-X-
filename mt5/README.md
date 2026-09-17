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
| `AutopsyX.mqh` | 2, 17, 19, 21, 22 | Facade — the only file your EA needs to include |

`AutopsyX_Example_EA.mq5` shows the full call sequence. It deliberately
stops short of a real `OrderSend` — the `TODO` inside `OnApprovedSignal()`
marks exactly where your EA's existing execution code goes, unchanged.

## What this honestly can and can't source

MT5 has no native feed for market breadth, "real yields," or Fed
expectations, and VIX/DXY/2Y/10Y availability depends entirely on your
broker's symbol list. Rather than fabricate these, every engine here
degrades explicitly instead of guessing:

- **Breadth** (`SetBreadthInputs()` / `SetBreadthInputs()` global wrapper)
  is a pluggable external feed. Until you call it — from a script, a
  bridge, or wiring it to the `server.js` bridge already in this repo's
  `server/` directory — breadth reads neutral (0) and its weight in the
  composite confidence contributes nothing, it does not fake a bullish or
  bearish tilt.
- **VIX/DXY/2Y/10Y** are optional config strings. Leave any blank, or
  point it at a symbol your broker doesn't actually list, and that leg is
  dropped from the macro/volatility score with `DATA_STATUS = DEGRADED`
  logged — never silently treated as calm or bullish (spec section 20).
- **Real yields / Fed expectations** are built from 2Y/10Y *momentum* on
  whatever CFD symbols your broker lists (if any), plus a manual
  inflation-expectation input for the real-yield proxy. This is a
  documented approximation, not a market-sourced number — treat
  `GetMacroScore()` as a directional read, not a precise print.
- **Economic calendar** (`AutopsyEventFilter.mqh`) tries MT5's
  `CalendarValueHistory`/`CalendarEventById` first; not every broker
  server feeds it. `AddManualEvent()` is the reliable baseline — schedule
  FOMC/CPI/NFP/etc. by hand and the live calendar becomes a bonus layered
  on top, not the only source.
- **Correlation protection** only sees exposure reported (via
  `ReportOwnExposure()`) by other AutopsyX instances on the **same MT5
  terminal**. It cannot see positions in a different terminal or account.

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
