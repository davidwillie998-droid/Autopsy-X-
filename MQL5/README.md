# AUTOPSY X FLIPDEMON EXTREME

Ultra-aggressive MT5 HFT flipping & scalping Expert Advisor.

`SCAN -> SCORE -> ATTACK -> MANAGE -> FLIP -> EXIT -> REASSESS`

This EA makes no profitability promises. It is an experimental, high-risk,
short-horizon trading engine whose only job is to be objectively testable —
after spread, commission, slippage, and execution costs — before anyone
risks real capital on it. Read this whole document before attaching it to a
live or demo account.

## What this is not

- Not a guaranteed-profit system. No win-rate or return figure below is a
  promise.
- Not a martingale or grid system. It never doubles a lot after a loss and
  never averages down a losing position.
- Not a black box. Every closed trade is written to a CSV log
  (`AutopsyX_FlipDemon_Extreme_<SYMBOL>_TradeAutopsy.csv` in the terminal's
  `MQL5/Files` folder) with the full reasoning, scores, and outcome
  classification behind it.

## 1. Installation

1. Copy the contents of this repository's `MQL5/` folder into your MT5
   terminal's data folder `MQL5/` directory (File -> Open Data Folder in
   MetaTrader 5), merging:
   - `MQL5/Include/AutopsyX/*.mqh` -> `<data folder>/MQL5/Include/AutopsyX/`
   - `MQL5/Experts/AutopsyX/AutopsyX_FlipDemon_Extreme.mq5` ->
     `<data folder>/MQL5/Experts/AutopsyX/`
2. In MetaEditor, open `AutopsyX_FlipDemon_Extreme.mq5` and compile
   (F7). It must compile with zero errors. See "Compilation" below for
   why this repository cannot compile it for you.
3. In MT5, open a chart for the symbol you want to trade (XAUUSD, EURUSD,
   GBPUSD, USDJPY, GBPJPY, NAS100, US30, BTCUSD, or any other broker
   symbol — see "Broker adaptation" below).
4. Drag `AutopsyX FlipDemon Extreme` onto the chart.
5. Pick a risk mode (`InpMode`) and review the input groups.
6. Enable AutoTrading (Ctrl+E) and confirm "Allow Algo Trading" is checked
   in the EA's Common tab.

No web server, API, or database is required. The engine runs entirely
inside the terminal process.

## 2. Compilation

This repository was built in a Linux container with no MetaTrader 5
installation and no MetaEditor/`metaeditor64.exe` available — there is no
MQL5 compiler on this machine. The code was written and hand-reviewed for
MQL5 syntax and API correctness (types, standard-library signatures,
include-guarding against the multi-include diamond problem that this
module layout creates, etc.), but **it has not been machine-compiled**.
Compile it yourself in MetaEditor before doing anything else, and if the
compiler flags something, treat this README's design description as
intent and the `.mq5`/`.mqh` files as the thing to fix.

## 3. Modules

| File | Responsibility |
|---|---|
| `Defs.mqh` | Shared enums/structs used by every other module |
| `MarketData.mqh` | Broker-adapted symbol properties + rolling tick buffer |
| `Momentum.mqh` | Tick velocity/acceleration, displacement, volatility, persistence, exhaustion |
| `Microstructure.mqh` | Tick imbalance, spread state, volatility expansion -> BUY/SELL components |
| `Liquidity.mqh` | Swing/equal/session highs & lows, sweep -> rejection -> displacement sequencing |
| `Regime.mqh` | TREND/STRONG_TREND/BREAKOUT/RANGE/MEAN_REVERSION/HIGH_VOL/LOW_VOL/CHAOTIC/UNSAFE classification |
| `SignalScore.mqh` | Combines the above into independent 0–100 BUY/SELL scores + confidence |
| `FlipEngine.mqh` | Multi-factor confirmation required before reversing a held position |
| `AntiChop.mqh` | Detects hostile chop and imposes adaptive cooldown / aggression reduction |
| `RiskEngine.mqh` | Position sizing, daily loss limit, consecutive-loss lockout, exposure/flip/trade-rate caps, kill switch state |
| `EntryEngine.mqh` | Pre-trade checklist; cancels an entry if conditions deteriorate before execution |
| `ExecutionEngine.mqh` | `CTrade`-based order wrappers; never assumes a fill — always confirms position state |
| `ExitEngine.mqh` | Dynamic SL/TP, break-even, momentum-adaptive trailing, fast defensive exits |
| `TradeAutopsy.mqh` | Per-trade CSV log + rule-based classification |
| `Statistics.mqh` | Win rate / profit factor / expectancy / drawdown / directional accuracy / profitability gate |
| `Dashboard.mqh` | On-chart panel + KILL ENGINE button |

## 4. Risk modes

| Mode | Risk per trade |
|---|---|
| `AX_MODE_NORMAL` | 0.5% |
| `AX_MODE_AGGRESSIVE` | 1.0% |
| `AX_MODE_EXTREME` | up to `InpExtremeRiskPercent`, hard-capped at 2.0% |

Aggression comes from faster decisions, tighter execution windows, and
willingness to flip direction — never from position-size escalation.
`RiskEngine.Configure()` hard-clamps risk to 2% regardless of input, and
there is no code path anywhere in this EA that increases lot size after a
loss.

## 5. Kill switch

Click **KILL ENGINE** on the dashboard, or the EA will activate it
automatically after `InpMaxConsecutiveExecFailures` consecutive broker
execution failures (a proxy for "catastrophic execution conditions" — the
EA cannot reliably distinguish a broker outage from a bad fill, so it
treats repeated failures the same way). Once killed: no new entries, the
open position is closed if `InpCloseAllOnKill` is true, and all trade
statistics are preserved. Re-attaching the EA (or restarting the terminal)
clears the kill state — this is deliberate, so a kill is never silently
"sticky" across a fresh, deliberate restart.

## 6. Testing methodology — read this before trusting any result

The EA includes a live-session `Statistics.EvaluateGate()` heuristic shown
on the dashboard as `GATE:`. **That heuristic is not a substitute for the
process below.** It exists to stop you from calling a single good session
"validated." Follow all five phases before risking meaningful capital:

1. **Historical tick backtest.** MT5 Strategy Tester, "Every tick based on
   real ticks" model, with your actual broker's historical spread if
   available. Run on each target symbol separately.
2. **In-sample optimization.** Optimize inputs only on a defined historical
   window. Do not touch the out-of-sample window while doing this.
3. **Out-of-sample validation.** Re-run the optimized parameter set,
   unchanged, on a later period the optimizer never saw. A large gap
   between in-sample and out-of-sample results means the parameters were
   fitted to noise — discard them and do not re-optimize on the
   out-of-sample window (that just moves the overfitting problem).
4. **Completely unseen data.** A third period, ideally a different
   volatility regime, still untouched by optimization.
5. **MT5 demo forward test.** Real-time demo account, live spread,
   execution latency, and broker behavior, for a period long enough to
   accumulate the trade count in "Profitability gate" below.

Across every phase, use realistic spread, commission, slippage, and
execution delay — never the Strategy Tester's default zero-cost
assumptions. A strategy that only wins before costs is not a strategy.

### Profitability gate

| Result | Meaning |
|---|---|
| `FAIL` | Net expectancy (after all costs) is negative. |
| `WEAK` | Profitable only before costs — net expectancy ≤ 0 but gross expectancy > 0. |
| `PROMISING` | Profitable after costs, but the sample is too small or too unstable across out-of-sample data to call it validated. |
| `VALIDATED` | Profitable after costs across a large enough sample, with acceptable drawdown and profit factor, in unseen data and forward testing. |

A high win rate with negative net expectancy is a `FAIL`, full stop —
win rate alone never overrides this. Never treat a single backtest's
positive result, or a short demo run, as `VALIDATED`; the dashboard's
`GATE` field only ever reflects the current live session's trade sample.

## 7. Broker adaptation

The EA reads digits, point, tick size/value, contract size, min/max
lot, volume step, stops level, freeze level, and execution mode directly
from the symbol at runtime — it hard-codes no pip assumptions. Confirm the
exact symbol name your broker uses (`XAUUSD` vs `GOLD`, `US30` vs `DJ30`,
`BTCUSD` vs `BTCUSD.`, etc.) before attaching the EA; it only trades the
symbol of the chart it is attached to.

## 8. Key inputs worth understanding before you change them

- `InpMinScoreToAct` / `InpMinGapToAct` — how decisive the BUY/SELL score
  split must be before any action is considered.
- `InpFlipRequiredConfirmations` / `InpFlipMinConfidence` — how much
  evidence the Flipdemon Reversal Engine needs before it closes and
  reverses a held position. Higher = fewer, more confident flips.
- `InpMaxHoldSeconds`, `InpEmergencySlPoints`, `InpDynamicTpRR` — the hard
  ceiling on how long a position is held and how far the emergency stop
  and take-profit sit from entry.
- `InpDailyLossLimitPercent`, `InpMaxConsecutiveLosses` — the two
  session-ending brakes. Once tripped, the EA stops trading for the
  session; it never attempts to "win back" a loss automatically.

## 9. Trade autopsy log

Every closed trade writes one CSV row with entry/exit time, direction,
prices, lot size, spread, slippage, hold time, BUY/SELL scores,
confidence, regime, entry/exit reasons, MFE/MAE, gross profit, commission,
swap, net profit, and a rule-based classification (correct momentum,
false breakout, liquidity trap, late entry, premature exit, momentum
failure, correct/false flip, spread/slippage failure, stop loss, take
profit, or risk shutdown). Use this file — not the dashboard's live
numbers alone — for any serious post-session analysis.
