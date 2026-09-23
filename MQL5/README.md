# AUTOPSY X FLIPDEMON EXTREME

> This document covers only `AutopsyX_FlipDemon_Extreme.mq5` and its
> `MQL5/Include/AutopsyX/` engine modules. `MQL5/Experts/AutopsyX/AutopsyXFlipdemonX15.mq5`
> is a separate Expert Advisor in the same folder — a single-file,
> fail-closed autonomous EA (structure/liquidity setups, VWAP, VP-MACD,
> News Defense, journal-gated risk; defaults to ANALYSIS_ONLY). It does not
> `#include` these modules; it ports some of their patterns with the
> safety changes noted in its source. It is not the FLIPDEMON EXTREME
> system described below. It documents
> itself in full in its own file header; see the root `README.md` for a
> summary of both.

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
external links used as documentation, no collection of users' personal
data, no profit promises in the product listing, and no third-party
support channels (Telegram, Discord, etc. — support has to run through
`mql5.com`'s own comments/messaging). This codebase has none of those — no
`#import`, no `WebRequest`, no network calls of any kind, no data
collection, no messenger links anywhere in the docs, and the "no
profitability promises" posture in this README is the same posture the
code itself takes (`GATE:` is a live heuristic, never a claim). It should
clear that bar as written. Two things code can't satisfy on its own: the
product title has to start with a capital letter and read clearly to a
non-professional (the current name does), and everything else — compiling
to `.ex5`, writing the actual product page, running the Market's own
pre-publication checks — happens outside this repository.

**File I/O and data locality.** `TradeAutopsy.mqh` logs every closed trade
to a CSV via `FileOpen()` without the `FILE_COMMON` flag, which keeps it in
the calling terminal's own sandboxed `MQL5/Files/` folder rather than the
machine-wide Common folder shared across every terminal installed. Nothing
in this codebase reads, writes, or transmits anything outside that one
sandboxed, per-terminal file.

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

Related but distinct: `EntryEngine.mqh` checks `SymbolInfoInteger(symbol,
SYMBOL_TRADE_MODE)` before every entry and refuses to trade a symbol the
broker has set to `SYMBOL_TRADE_MODE_DISABLED` or
`SYMBOL_TRADE_MODE_CLOSEONLY` — the broker/exchange-side equivalent of the
account-side hedging guard: don't act on a signal the venue itself won't
accept.

**Financial-regulatory compliance (CFTC/NFA, FCA, ESMA, etc.).** These
regimes regulate brokers and dealers, not the EA itself, but a few things
carry over to how you use it:

- *No profitability promises.* Regulators across these regimes require
  retail forex/CFD marketing to avoid misleading performance claims. This
  EA and its documentation are built the same way for a different reason
  (intellectual honesty about an untested strategy) — the profitability
  gate is explicitly a live-session heuristic, never a claim.
- *Leverage caps and negative-balance protection* are enforced by the
  broker on the account, not by the EA. ESMA's tiered caps: 30:1 major FX
  pairs, 20:1 non-major pairs/gold/major indices, 10:1 commodities other
  than gold and minor indices, 5:1 individual equities, 2:1 crypto CFDs.
  CFTC/NFA: 50:1 major pairs, 20:1 everything else. These constrain
  available margin, which `RiskEngine`'s pre-trade margin-level check
  already respects dynamically — no EA-side leverage configuration exists
  or is needed.
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

## 13. Sniper entries — precision over frequency

A confirmed signal used to be the whole trigger: score clears the bar, the
next tick fires a market order. That's fine on paper and expensive in
practice, because a signal firing *right now* usually means the move
already thrust, and market orders chasing a thrust pay the worst price of
the whole move. `CSniperEngine` (`Include/AutopsyX/SniperEngine.mqh`)
changes what happens between "signal confirmed" and "capital committed."

**How it works.** Once every other gate (risk, chop, session, HTF
confluence) has passed for a fresh signal, the EA no longer fires — it
arms. From that point every tick is watched for a genuine two-phase
structure event in the signal's own direction:

1. **A pullback** of at least `InpSniperPullbackPoints` away from the best
   price seen since arming. This is proof the initial thrust paused instead
   of running away untouched.
2. **A resumption** of at least `InpSniperResumePoints` back in the
   original direction, measured from the pullback's own extreme. This is
   the actual retest-and-go that the entry fires on.

Only the resumption commits capital, at whatever price the market is
offering at that moment — typically a meaningfully better price than the
one available the instant the signal first confirmed. Two safeguards keep
this from turning into missed trades or a chase in disguise:

- **Never chase.** If price runs more than `InpSniperMaxChasePoints` in the
  signal's favor *before ever pulling back*, the arm is abandoned outright.
  A move that never offers a retest is not a sniper entry, it's a breakout
  this EA deliberately sits out.
- **Never wait forever.** `InpSniperMaxWaitSeconds` bounds how long an
  armed signal is allowed to wait for its retest. Conditions that produced
  the original signal can go stale; an unbounded wait would eventually
  fire on a signal the market has already invalidated.

`FinalConfirm` still runs at the moment of the actual trigger (same as the
legacy one-tick-delay path), so a retest that fires into a spread spike or
a since-flipped score gets cancelled rather than forced through.

**Structure-based stops.** Sniper precision extends to risk placement.
When `InpSniperUseStructureStop` is enabled, the entry's stop-loss prefers
the nearest tracked liquidity/swing level (`CLiquidityEngine::GetNearestLevel`)
plus `InpSniperStructureBufferPts`, instead of the generic ATR/fixed
distance — but *only* when that structural stop is actually tighter than
what `ComputeInitialStops` already produced, and only when it still clears
the broker's minimum stop/freeze distance. This never widens risk, it only
sharpens it: since position sizing is computed from the actual resulting
stop distance, a tighter, structure-anchored stop yields a larger position
for the same fixed dollar risk, not a smaller one.

**Scope.** Sniper timing applies only to fresh entries taken while flat.
Flip re-entries — closing one side and immediately opening the other on a
confirmed reversal — remain immediate and unaffected. A flip is a
defensive, time-critical reaction to a reversal already in progress;
waiting for a pullback-and-resume there would defeat the purpose of
flipping at all.

**Turning it off.** `InpUseSniperEntry=false` restores the exact prior
one-tick confirmation-delay behavior with no other change in behavior —
useful as an A/B baseline, or on symbols/timeframes where pullbacks are
too rare or too fast to be usable. The dashboard's SNIPER line shows OFF,
IDLE, or ARMED with a live pullback/resume phase and wait-timer so you can
see the state machine working in real time rather than inferring it from
trade timestamps after the fact.

## 14. Order flow, footprints, volume profile, heatmap, pulse

Five modules that read the market's internal structure rather than just
price — `Include/AutopsyX/OrderFlow.mqh`, `Footprint.mqh`,
`VolumeProfile.mqh`, `Heatmap.mqh`, `Pulse.mqh`. All five are advisory:
they add a bounded bonus to the existing BUY/SELL score
(`InpOrderFlowScoreWeight` points max, per module, per side — up to 4x
that when the heatmap is also available) through
`AxApplyOrderFlowBonus()`, and can genuinely tip a borderline score over
the action threshold or hold back a contradicted one — but none of them
is a hard gate the way HTF confluence is. Turn the whole group off with
`InpUseOrderFlow=false` to get the pre-existing score exactly as before.

**The honest caveat first.** A retail MT5 forex/CFD feed is quotes (bid/ask),
not a trade tape. There is usually no real "buyer lifted the offer" flag on
a tick. Every module below that needs a buy/sell split infers it the same
way the rest of this EA already infers direction: which way the mid price
moved, tick to tick. That's a reasonable, widely-used proxy — it is not the
same thing as a genuine exchange trade-and-quote feed, and stacked-imbalance
or absorption readings should be read as "the price action *looked like*
this," not as ground truth about actual buyer/seller identity.

- **Order flow** (`COrderFlowEngine`). A session cumulative delta (CVD,
  resets at the broker's midnight) plus a rolling-window buy/sell volume
  imbalance ratio (-1..+1). Also flags **absorption**: heavy one-sided
  volume that *failed* to move price — heavy selling that didn't push
  price down implies hidden buying strength (bullish absorption), and the
  mirror case for bearish. Volume weight is the feed's real traded size
  when available, else a per-tick count proxy, so CVD stays meaningful
  even on a broker reporting flat "1 per tick" volume.
- **Footprints** (`CFootprintEngine`). Bins order flow's per-tick
  buy/sell classification into price levels *within the currently forming
  bar* — the actual definition of a footprint, and the one thing volume
  profile can't give you since it has no direction. At bar close it scans
  the finished grid for **stacked imbalance**: several consecutive price
  levels all lopsidedly one-sided (`InpFootprintImbalanceRatio`,
  `InpFootprintStackedLevels`), a classic aggression/exhaustion tell.
- **Volume profile** (`CVolumeProfileEngine`). POC (point of control) and
  a 70% value area (VAH/VAL), built from completed bars' `tick_volume`
  spread evenly across each bar's High-Low range — rebuilt once per new
  bar over a rolling lookback (`InpVolumeProfileBars`), the same cadence
  `CLiquidityEngine::RefreshLevels` already uses, never per tick. Feeds a
  breakout-confirmation lean when price pushes outside the value area.
- **Heatmap** (`CHeatmapEngine`). Subscribes to the broker's order book
  (`MarketBookAdd`/`MarketBookGet`) and tracks buildup vs. pull of resting
  size near the touch price between refreshes — a growing level is read as
  a wall forming, a shrinking one as being pulled. **Most retail
  forex/CFD symbols on MT5 provide no real depth at all.** This is
  detected, not papered over: the dashboard shows `HEATMAP: N/A (no
  broker depth)` and the score contribution is a hard zero rather than a
  fabricated reading. Refreshed once a second from the dashboard's own
  timer (`OnTimer`), not the tick loop — DOM reads are heavier than a
  tick and don't need tick-rate freshness to stay useful. If
  `InpShowDashboard=false` the timer never runs and the heatmap never
  refreshes; a genuinely dashboard-independent DOM feed wasn't judged
  worth a second timer chain for this feature.
- **Pulse** (`CPulseEngine`). One compact 0-100 "is the market alive
  right now" gauge plus a direction lean, blending tick velocity, order-
  flow imbalance magnitude, volatility expansion, and spread quality. It
  is a dashboard read, not a gate by default — it's the fastest way to
  glance at the chart and tell whether current conditions are worth
  watching at all, in a single number, rather than cross-referencing four
  separate readouts.

**Dashboard.** All five surface on the panel: CVD + rolling imbalance,
absorption direction, volume-profile position relative to the value area,
the last completed bar's footprint stacking, the pulse gauge, and the
heatmap wall-pressure split (or its honest "N/A").

## 15. Adaptive Flip Engine — capital protection

`Include/AutopsyX/AdaptiveFlipEngine.mqh` is a capital-protection layer
that sits on top of `CRiskEngine`, not in place of it. It never touches
`CRiskEngine`'s own limits or its position-sizing formula — it only ever
scales the resulting lot size **down** (never up) and adds its own hard
gates, evaluated on every entry attempt: fresh signals, sniper triggers,
and flip re-entries alike. A flip closing a losing side and re-opening the
other way is still new risk, so it gets no exemption from capital
protection — that's the point of "account-agnostic": every reading here
is a percentage, a ratio, or an R-multiple, never a currency amount, so
none of it needs retuning when account size changes.

**Why this exists alongside what was already there.** `CRiskEngine`
enforces a daily loss limit anchored to the trading day, and a
consecutive-loss counter that resets with it. Neither catches a slow
bleed spread across many days that never breaches either limit on any
single day. `AxAdaptiveConfidenceMultiplier` (pre-existing) nudges the
entry confidence bar from trailing win rate — a coarse edge-decay
response, but it only ever changes the threshold for taking a trade, never
how big that trade is or whether it should be blocked outright regardless
of confidence. The Adaptive Flip Engine (AFE) closes both gaps: continuous
peak-equity drawdown tracking instead of a day-anchored one, and hard
gates plus a graduated size-down instead of a threshold nudge alone.

**Capital state ladder**, driven by drawdown from the highest equity ever
seen (not the day's opening equity). That peak is persisted to a GlobalVariable
keyed by symbol and magic number, so an EA/terminal restart mid-drawdown
doesn't silently re-seed the peak to the already-drawn-down current
equity and reset straight back to NORMAL — the one event (a crash during
a bad drawdown) this continuous tracking most needs to survive. MT5
global variables live on disk for roughly 4 weeks of inactivity or until
a manual reset; they do not follow the account to a different terminal
installation or machine.
- **NORMAL** — full configured risk.
- **CAUTION** (`InpAfeCautionDdPct`, default 8%) — risk scaled by
  `InpAfeCautionMultiplier` (default 0.65x).
- **DEFENSIVE** (`InpAfeDefensiveDdPct`, default 15%) — risk scaled by
  `InpAfeDefensiveMultiplier` (default 0.30x).
- **LOCKED** (`InpAfeLockedDdPct`, default 25%) — new entries hard-blocked
  entirely. The state is recomputed fresh from current drawdown every
  tick with no hysteresis, so it drops straight back to DEFENSIVE the
  moment drawdown ticks back under 25% — not down to the CAUTION or
  NORMAL line. If you want a wider recovery margin before risk resumes,
  set `InpAfeLockedDdPct` with that gap already built in.

**Win probability and expected value.** Every entry attempt gets a
blended win-probability estimate: once `InpAfeMinTradesForStats` trades
exist, it's half the trailing realized win rate and half the current
signal's own score confidence; before that, it leans on the live score
alone rather than a noisy small sample. Expected value is then computed
in **R-multiples** (1R = the amount risked on the trade) using the
realized win/loss ratio once there's history, or
`InpAfeAssumedRewardRisk` (default 1.5) before there is. An entry whose
EV falls below `InpAfeMinExpectedValueR` (default 0.0 — literally
"positive expectancy required") is blocked.

**Risk of ruin — read this caveat before trusting the number.**
`InpAfeMaxRiskOfRuinPct` (default 5%) gates entries against a **classic
closed-form gambler's-ruin approximation** adapted to fixed-fractional
position sizing. It is a heuristic, not an exact result: it assumes
independent trade outcomes and a roughly constant edge and risk fraction
per trade, neither of which is exactly true of live markets. "Ruin" here
means falling `InpAfeRuinThresholdPct` (default 50%) from peak equity, not
literal bankruptcy — fixed-fractional sizing asymptotically approaches but
never mathematically reaches zero. Treat this number the way you'd treat
any other risk estimate in trading literature: directionally useful,
not a guarantee.

**Account health** blends margin level and current drawdown-from-peak
into one 0-100 score; entries are blocked below `InpAfeMinAccountHealth`
(default 25).

**Execution-quality scaling.** Reuses the poor-fill streak the EA already
tracks (see section 12) for a softer, earlier size-down (0.70x at one
consecutive poor fill, 0.40x at two) ahead of the outright kill switch
that fires later at `InpMaxConsecutivePoorFills`.

**Trade autopsy integration.** Rather than a second logging system, AFE's
readings at the moment of entry (capital state, risk of ruin, expected
value, win probability, the risk multiplier actually applied) are carried
through `SAxPositionState` into the closed-trade record and written as
five extra columns on the existing autopsy CSV — so you can see, after
the fact, exactly what AFE believed about a trade when it let it through.

**Turning it off.** `InpUseAdaptiveFlipEngine=false` skips every AFE gate
and returns a risk multiplier of exactly 1.0 — a true A/B baseline against
every earlier round of work in this file. The dashboard's AFE section
reflects live readings whenever it's on; note that risk-of-ruin, expected
value, win probability, and account health only update at the moment of
an actual entry attempt (that's the only point they can affect anything),
so they hold their last value while a position is open or the engine is
idle between signals, rather than refreshing every tick.

## 16. Grounded in the literature — Patnaik & Thomas (2004)

Two changes in this round come directly from a specific academic paper
rather than general trading folklore: Tirthankar Patnaik & Susan Thomas,
*"Profitability of Trading Strategies on High-Frequency Data, with
Trading Costs"* (2004), a study of contrarian/momentum strategies on
NSE (Indian equity) intraday order-book data, 1996-2002.

**The honest scope caveat first.** That paper studies multi-day,
cross-sectional equity portfolios (formation periods of 25-250 *days*,
holding periods to match) — nothing about its specific parameters
transfers to a tick-level single-instrument scalping EA. What transfers
is the **methodology**, and two of its findings are general enough to
apply here directly:

- **Non-proportional trading costs must be measured from the actual
  order book, not inferred from spread.** The paper's central technique:
  for a trade of a given size, walk the limit-order book to find the
  real weighted-average execution price, and compare it to the best
  available price — that gap is the "impact cost," and it's *size-
  dependent*, not proportional. A fixed spread tolerance says nothing
  about what a large order actually pays once it eats through the book.
  This EA already scaled deviation tolerance to spread (section 12) but
  had no notion of size-dependent cost at all. `CHeatmapEngine::EstimateExecution`
  (new) does exactly the paper's walk: for the prospective order, it
  sums quantity × price level by level away from the best price,
  computes the running average impact-cost percentage, and — new in
  `AxAttemptEntry` — caps position size to the largest amount fillable
  within `InpMaxImpactCostPct` (default 0.15%). Same graceful-degrade
  rule as the rest of the heatmap suite: no real depth from the broker
  means this is a no-op (`InpUseImpactCostSizing` toggles it off
  outright), not a fabricated cost. The measured impact cost for the
  originally-intended size is recorded on the dashboard (next to the
  HEATMAP line) and as a new `ImpactCostPct` autopsy CSV column.

- **Momentum profits rise with holding period, once the formation
  period is short.** The paper's Table 6: for the same short formation
  window, profits at a 250-day hold run roughly 3-4x those at a 25-day
  hold. An *unconditional* time-based exit throws away exactly the
  trades that finding says are worth holding onto. `CExitEngine::Evaluate`'s
  `MaxHoldSeconds` check is now two-tiered: a **soft** cutoff at
  `InpMaxHoldSeconds` that's skippable only while the position is both
  currently in profit *and* momentum is still persistent/not exhausted
  in its own direction, and a **hard**, unconditional backstop at
  `InpMaxHoldSeconds × InpMaxHoldExtensionMultiplier` (default 2.0) that
  fires no matter what. Every other defensive exit (momentum collapse,
  microstructure reversal, opposing signal, abnormal spread) stays fully
  active regardless — a position that's genuinely turning still gets cut
  fast. `InpMaxHoldExtensionMultiplier=1.0` collapses soft into hard and
  restores the exact prior unconditional-cutoff behavior.

- **Not implemented, and why**: the paper's third major finding — that
  momentum profits are driven roughly 50-80% by cross-sectional
  correlation across a *basket* of stocks, not by a single instrument's
  own serial autocorrelation — doesn't have a faithful single-instrument
  analogue here without adding a second, separately-subscribed symbol as
  a benchmark, which is a materially different feature (and a separate
  data-reliability surface) from what this round scopes. Noted for a
  future round rather than force-fit into something it doesn't cleanly
  become.
