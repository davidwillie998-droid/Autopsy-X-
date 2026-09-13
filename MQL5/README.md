# AUTOPSY X HFT FLIP ENGINE — MT5 Expert Advisor

Institutional-grade, single-terminal MT5 high-frequency flip trading engine.
`Detect -> Validate -> Enter -> Capture -> Exit -> Reassess.` Default behaviour
is always **NO TRADE** unless multiple independent signals agree.

## Install (single terminal, no external infrastructure)

1. Copy the `Experts/AutopsyX`, `Include/AutopsyX` and `Scripts/AutopsyX` folders
   into your MT5 `MQL5` data folder (File -> Open Data Folder -> `MQL5`),
   preserving the folder structure so the includes resolve.
2. In MetaEditor, open `Experts/AutopsyX/AutopsyX_HFT_Flip.mq5` and compile
   (F7). It has no external dependencies beyond the standard MQL5 API.
3. In MT5, attach `AutopsyX_HFT_Flip` to a chart of the symbol you want to
   trade (XAUUSD, EURUSD, GBPUSD, USDJPY, GBPJPY, NAS100, US30, BTCUSD, or any
   other MT5 symbol — all execution properties are auto-detected, nothing is
   hard-coded per symbol).
4. Set `InpRiskPerTradePct` and the other risk-engine inputs to taste.
5. Set `InpEnableTrading = true`.
6. AUTOPSY X handles the rest — no API, no database, no web server required.

## What it does

The EA is built as a pipeline of independent, individually testable modules
under `Include/AutopsyX`:

```
MarketDataEngine -> MicrostructureEngine -> LiquidityEngine -> MomentumEngine
-> RegimeEngine -> ConfidenceEngine -> EntryEngine -> ExecutionEngine
-> ExitEngine -> RiskEngine -> AutopsyEngine
```

- **MicrostructureEngine** — tick direction, velocity, acceleration,
  displacement, spread dynamics, short-term volatility, momentum
  persistence/exhaustion, computed from a fixed-size rolling tick buffer.
- **LiquidityEngine** — sweep -> rejection -> displacement -> confirmation.
  A sweep alone never triggers an entry.
- **MomentumEngine** — swing-based short-term structure, micro
  support/resistance breaks, displacement strength.
- **RegimeEngine** — classifies TRENDING / BREAKOUT / MEAN REVERSION / RANGE
  / HIGH VOL / LOW VOL / CHAOTIC / UNSAFE from one ATR handle + trend slope +
  chaos ratio, and re-weights the confidence engine accordingly.
- **ConfidenceEngine** — weighted BUY/SELL scoring; only trades when the
  winning side clears both an absolute threshold and a minimum edge over the
  other side. Ambiguous conditions (e.g. 48 vs 51) always resolve to NO TRADE.
- **RiskEngine** — per-trade risk sizing, daily loss limit, drawdown
  shutdown, consecutive-loss cooldown, max trades/flips per minute and per
  session, and a kill switch that never self-clears.
- **EntryEngine** — final pre-trade re-validation (spread, session, margin,
  signal freshness) immediately before sending the order; cancels rather than
  chases if anything has deteriorated.
- **ExecutionEngine** — raw `MqlTradeRequest`/`OrderSend` with bounded retry
  on transient broker errors, and full signal/submit/fill timestamp +
  slippage tracking.
- **ExitEngine** — momentum reversal, opposing-score dominance, spread
  blowout, max holding time, breakeven, micro trailing, hard SL/TP.
- **AutopsyEngine** — classifies every closed trade (correct read, late
  entry, false breakout, liquidity trap, momentum failure, spread/slippage
  failure, premature/correct exit, ...) and journals it to
  `MQL5/Files/AutopsyX/<symbol>_journal.csv`. A plain-text performance report
  is written to `MQL5/Files/AutopsyX/<symbol>_report.txt` on removal / test
  end, and printed by `OnTester()` when run in the Strategy Tester.
- **AdaptiveEngine** — bounded self-tuning of entry/exit thresholds, tick
  window, holding-time limit and trailing distance. Every adaptive parameter
  has a hard, non-negotiable min/max (see `AX_ADAPT_*` constants in
  `Include/AutopsyX/Defines.mqh`).

## Live calibration (why demo settings don't carry over)

Demo and live servers do not fill orders the same way — most brokers simulate
friendlier spread and slippage on demo, so nothing you learn there tells you
the real spread/slippage regime on the account you actually intend to trade.
There is no way around this at the platform level; being connected to the
live server is the only source of truth about that account's real execution
quality.

So rather than trade on a guessed static spread/deviation number, the EA
opens in a `CALIBRATING` state (see `Include/AutopsyX/LiveCalibrationEngine.mqh`)
whenever `InpLiveCalibrationEnabled` is on (default): for `InpCalibrationMinutes`
it watches real ticks on whichever account it is attached to — live included —
places **no trades**, and measures the account's actual median and 90th-percentile
spread. Once it has enough samples it derives:

- the spread gate (`P90 spread * InpSpreadToleranceMultiplier`)
- the minimum-displacement filter (`median spread * InpDisplacementCostMultiplier`)
- the minimum-ATR filter (`median spread * InpAtrCostMultiplier`)
- the execution deviation tolerance (`P90 spread * InpDeviationToleranceMultiplier`)

from what it actually measured on that broker/symbol/session, and prints the
measured numbers to the log. Only after that does it leave `CALIBRATING` and
start evaluating entries. If a symbol is too illiquid to gather enough samples
before the window (times out at 3x `InpCalibrationMinutes`) it falls back to
the static `Inp*` inputs and says so in the log.

**What this does not do:** it does not make live trading risk-free, and it is
not a substitute for validating the strategy itself. Recommended path for a
live-only rollout: attach on live with the smallest lot size your broker
allows and `InpRiskPerTradePct` set very low, let calibration complete, and
watch the dashboard + `MQL5/Files/AutopsyX/<symbol>_journal.csv` for a real
probation period before raising size. That first live stretch, at minimum
risk, is the only genuine test of this account's execution quality — there
is no shortcut that avoids putting real money on the line for it.

## Dashboard

A lightweight on-chart panel (status, regime, direction, buy/sell score,
confidence, spread, tick velocity, momentum, trades today, win rate, daily
P/L, drawdown, current position, hold time, exit mode) refreshes on a timer
(`InpDashboardRefreshMs`, default 500ms) — never on every tick — so it cannot
interfere with execution.

## Testing components independently

Run `Scripts/AutopsyX/AutopsyX_SelfTest.mq5` from the Navigator on any chart.
It exercises the symbol profile, tick buffer, microstructure, liquidity,
momentum, risk, adaptive, autopsy and entry/exit-stop logic against synthetic
data and prints PASS/FAIL per assertion — no orders are placed. Full
strategy-level backtesting (net profit, profit factor, win rate, average
win/loss, max drawdown, consecutive losses, trade frequency, average holding
time, expected value, slippage impact, spread impact) is available by running
the EA itself in the MT5 Strategy Tester; `OnTester()` prints and the deinit
report file captures the same metrics from `AutopsyEngine::GenerateReport()`.

## Fail-safe priority

Capital preservation > execution quality > signal quality > trade frequency.
No measurable edge -> NO TRADE. Abnormal execution conditions -> NO TRADE.
Risk limits breached -> STOP. The kill switch only clears on an explicit
operator action (EA restart or `ManualReset()`), never automatically.
