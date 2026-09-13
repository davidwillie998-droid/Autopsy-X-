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

## 10. Advanced additions (v1.1)

A second review pass added the following on top of the original build. All
are additive — every one has a hard off switch, and none of them relax any
risk cap from section 4.

- **Higher-timeframe confluence** (`InpRequireHtfConfluence`,
  `InpHtfTimeframe`, `InpHtfMinR2ToBlock`). A second regime engine runs on
  a slower timeframe (H1 by default) purely as a filter: it blocks an
  entry only when the HTF has a *clear* trend (R² above the threshold)
  running opposite to the trade direction. An HTF with no clear opinion
  never blocks anything.
- **ATR-adaptive stops** (`InpUseAtrStops`, `InpAtrStopMultiplier`). The
  emergency stop distance widens to the larger of the fixed-point floor or
  an ATR multiple, so a volatile symbol/regime doesn't get stopped out by
  ordinary noise. Position size is calculated from the *actual* resulting
  stop distance, so a wider stop always means a smaller position — the
  dollar risk stays pinned to the configured risk percent regardless.
- **Session / rollover filter** (`InpSessionStartHour`,
  `InpSessionEndHour`, `InpAvoidRolloverMinutes`). An optional broker-time
  trading-hours window, plus an always-available filter that avoids the
  minutes around broker midnight where spreads typically spike.
- **Adaptive confidence tuning** (`InpAdaptiveTuning`,
  `InpAdaptiveLookbackTrades`, `InpAdaptiveMin/MaxMultiplier`). Recomputed
  once per bar (never per tick) from the trailing live trade sample: the
  entry confidence bar tightens after a poor stretch and relaxes slightly
  after a strong one, bounded within the configured multiplier range. It
  touches only the confidence gate — never position size, never any risk
  limit.
- **Partial profit-taking / scale-out** (`InpEnablePartialTP`,
  `InpPartialTriggerRR`, `InpPartialClosePercent`) — **off by default**.
  Banks a configurable percentage of the position once it reaches a
  configurable multiple of the initial stop distance; the remainder keeps
  trading under the same exit/trailing logic. The banked partial is logged
  as its own trade-autopsy row, and P&L accounting tracks exactly which
  broker deals (by deal ticket, not timestamp — MT5 deal time only has
  1-second resolution) have already been attributed so the eventual final
  close does not double-count the partial's profit. Known residual edge
  case: if the broker's deal-history cache lags more than ~80ms right
  after the partial fires (rare, under terminal/broker load), the partial
  row is logged with zeroed P&L and its real profit is instead swept into
  the final close's row — the total P&L stays correct, only its attribution
  across the two CSV rows can be off. If you rely on the per-partial P&L
  breakdown for analysis, sanity-check rows against your broker's own
  trade history.
- **Gross vs. net profit factor** — the dashboard and `SAxStatsSnapshot`
  now expose both `profitFactor` (after all costs — the honest number) and
  `grossProfitFactor` (before commission/swap), so a WEAK-gate verdict
  ("profitable only before costs") is visible at a glance rather than only
  inferred from expectancy.

A prior review pass also found and fixed a real correctness bug worth
naming explicitly: the FlipDemon reversal engine's re-entry originally
bypassed every risk gate and the anti-chop cooldown (only the closing leg
of a flip was gated). Every entry — fresh or flip re-entry — now funnels
through the same risk/chop/HTF checks; a confirmed reversal is always
allowed to close the losing side, but re-opening into the new direction is
just another entry subject to every hard limit.

## 11. Policy and regulatory notes

This is not legal advice. It's a factual account of how the code behaves
against three things worth checking separately: MetaQuotes' own MQL5
Market rules, broker/platform trading mechanics, and financial-regulatory
frameworks that govern retail forex/CFD accounts.

**MQL5 Market publishing rules.** If this is ever submitted to the Market,
MetaQuotes requires (among other things): no DLL/system-library calls, no
`WebRequest`-based third-party licensing/update/accounting systems, no
external links used as documentation, and no collection of users' personal
data. This codebase has none of those — no `#import`, no `WebRequest`, no
network calls of any kind, no data collection. It should clear that bar as
written. (Submission itself has separate steps — compiling to `.ex5`,
writing a product page, running the Market's own pre-publication checks —
that are outside what code alone can satisfy.)

**Broker/platform mechanics — FIFO and netting.** US-regulated accounts
(NFA Compliance Rule 2-43b) prohibit hedging and require first-in-first-out
closure of same-symbol positions. This EA's execution model already fits
that by construction: it tracks and manages exactly one net position per
symbol, closes fully (or partially, via scale-out) before ever opening the
opposite direction, and never holds simultaneous long and short tickets on
the same symbol. As of this review, `OnInit` also checks
`ACCOUNT_MARGIN_MODE` directly and refuses to start on a hedging-mode
account (`ACCOUNT_MARGIN_MODE_RETAIL_HEDGING`) — the EA's whole position-
tracking model assumes netting (one net position per symbol, managed via
`PositionSelect`), which a hedging account can violate the moment any other
order or EA opens a second ticket on the same symbol. Use a netting
account. Separately: available leverage and margin are set by the broker
and regulator, not by this EA — `RiskEngine` reads live account margin and
adapts to whatever the account actually has, but it does not and cannot
change what leverage you're offered.

**Financial-regulatory compliance (CFTC/NFA, FCA, ESMA, etc.).** These
regimes regulate brokers and dealers, not the EA itself, but a few things
carry over to how you use it:

- *No profitability promises.* Regulators across these regimes require
  retail forex/CFD marketing to avoid misleading performance claims. This
  EA and its documentation are built the same way for a different reason
  (intellectual honesty about an untested strategy) — the profitability
  gate is explicitly a live-session heuristic, never a claim.
- *Leverage caps and negative-balance protection* (ESMA: 30:1 major FX,
  20:1 minors/gold/major indices, down to 2:1 on crypto CFDs; CFTC/NFA:
  50:1 majors, 20:1 minors) are enforced by the broker on the account, not
  by the EA. They constrain available margin, which `RiskEngine`'s
  pre-trade margin-level check already respects dynamically — no EA-side
  leverage configuration exists or is needed.
- *Running this on your own account* as a retail trader operating through
  a licensed broker is not itself a regulated activity in any of these
  regimes. The line moves if you go further: distributing it for
  compensation as trading advice for others' accounts can trigger CTA
  registration considerations under the CEA in the US, and firms (not
  individual retail users) conducting algorithmic trading have their own
  notification/record-keeping obligations under MiFID II Article 17 in
  the EU. Neither applies to running the EA on your own account through
  your own broker; both are worth a real compliance conversation before
  offering it to anyone else.

## 12. Live-account execution realism

Demo execution is close to a fiction: fills are near-instant, slippage is
usually near zero, and spread rarely does anything a chart doesn't already
show you. None of that holds on a live account, so this EA no longer
treats "the order was accepted" as the end of the story.

**What changed to handle it:**

- **Fill latency is measured, not assumed.** Every market order times its
  own round trip (`ExecutionEngine::OpenMarket`'s `latencyMsOut`). A slow
  broker/network shows up as a number, not a guess.
- **Deviation scales to live spread**, not a single fixed value.
  `InpDeviationPoints` is now a floor; the actual allowed deviation sent
  with each order is `max(InpDeviationPoints, spread × InpDeviationSpreadMultiplier)`.
  A fixed deviation either rejects perfectly good fills the moment spread
  widens normally, or lets slippage run unchecked during a real spike —
  scaling it to current spread avoids both failure modes.
- **A live execution-quality circuit breaker now actually runs.**
  `RiskEngine::SlippageAcceptable` and the `AX_EXIT_EXECUTION_QUALITY` exit
  reason existed before this pass but were never wired to anything. Now:
  every fill's slippage and latency are checked against
  `InpMaxSlippagePoints` / `InpMaxFillLatencyMs`; `InpMaxConsecutivePoorFills`
  consecutive bad fills trips the kill switch outright, because repeated
  poor fills are a sign that current broker/network conditions aren't fit
  for this strategy right now — not something to keep trading through.
- **A position whose stops can't be managed gets cut, not left naked.**
  If `ModifyStops` (break-even/trailing) fails `InpMaxModifyFailures` times
  in a row on the same position — a live-only failure mode, since a demo
  server essentially never rejects a modify — the EA closes it with
  `AX_EXIT_EXECUTION_QUALITY` rather than continuing to hold a position it
  can no longer protect.
- **The account type is checked and shown, not assumed.** `OnInit` reads
  `ACCOUNT_TRADE_MODE` once and the dashboard shows a permanent LIVE/DEMO
  badge, plus running averages for slippage and fill latency and a
  poor-fills-today/streak counter — so you can see, on the chart, whether
  current conditions are actually clean or degraded, instead of inferring
  it from the equity curve after the fact.

**What this doesn't and can't do:** none of the above makes a broker
faster or a spread narrower. It measures what's actually happening and
protects capital when conditions are bad, rather than pretending demo-like
conditions apply. Tune `InpMaxSlippagePoints`, `InpMaxFillLatencyMs`, and
`InpMaxConsecutivePoorFills` to your specific broker and symbol — a
250ms round trip is unremarkable on some ECN feeds and alarming on
others, and default values are a starting point, not a promise.
