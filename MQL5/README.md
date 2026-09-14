# AUTOPSY X HFT FLIP ENGINE VX — MT5 Expert Advisor

Institutional-grade, single-terminal MT5 high-frequency flip trading engine.
`Detect -> Validate -> Enter -> Capture -> Exit -> Reassess.` Default behaviour
is always **NO TRADE** unless multiple independent signals agree.

**VX** adds an account-agnostic Adaptive Flip Engine on top of the same
strategy logic (see below) — nothing about signal generation, execution, or
exits changed; VX is a gating and sizing layer bolted on top.

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
-> RegimeEngine -> ConfidenceEngine -> AdaptiveFlipEngine (VX) -> EntryEngine
-> ExecutionEngine -> ExitEngine -> RiskEngine -> AutopsyEngine
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
- **AdaptiveFlipEngine (VX)** — account-agnostic probability/expected-value/
  account-health/risk-of-ruin gating and bounded dynamic position sizing,
  sitting between ConfidenceEngine and EntryEngine. See the dedicated VX
  section below.

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

## Volume profile, order flow, heatmap, pulse — what's real and what's a proxy

MT5 does not give retail EAs a real executed-trade tape (aggressor-side
buy/sell prints) for most OTC forex/CFD symbols — that's what genuine order
flow / footprint tools (an exchange feed into Bookmap, Sierra Chart, etc.)
are built on, and brokers don't expose it over the standard price feed. Be
clear-eyed about what each new module actually is:

- **`VolumeProfileEngine.mqh` — real.** Built from actual bar
  volume (`real_volume` where the broker reports it, `tick_volume`
  otherwise) bucketed by price over a rolling lookback. Produces a genuine
  Point of Control and 70% Value Area High/Low; trading above/below the
  value area is a real, standard volume-profile signal.
- **`OrderFlowEngine.mqh` — a proxy, not real order flow.** Since there's no
  trade-side data to read, buy/sell pressure is estimated with the classic
  *tick rule* (an uptick is treated as buy pressure, a downtick as sell
  pressure — a standard academic/industry approximation used whenever true
  aggressor data isn't available). It produces per-bar delta, cumulative
  delta, price/flow divergence, and absorption detection, and every label
  in the code and on the dashboard calls it "(proxy)" so it's never
  mistaken for a real footprint chart. It is not a substitute for an actual
  exchange-fed footprint tool.
- **`HeatmapEngine.mqh` — real when your broker supports it, honestly
  absent when it doesn't.** Tries `MarketBookAdd`/`MarketBookGet` (DOM) for
  the attached symbol. Where supported, it computes genuine bid/ask depth
  imbalance near the top of book. Where not — most OTC forex brokers don't
  expose a DOM — it reports `DOM unavailable` and contributes nothing
  (never fabricated) to the score.
- **`PulseEngine.mqh` — a derived composite, real inputs.** Blends tick
  velocity, bar volume and volatility against their own rolling EMA
  baselines into one 0–100 "how alive is this market right now" gauge. Used
  to further damp trading in a dead tape and give a small credit to
  genuinely active conditions — reinforcing the anti-overtrading engine,
  not overriding it.

All four feed into the confidence engine as additional weighted evidence
(`InpVolumeProfileLookbackBars`, `InpOrderFlowDivergenceWindow`,
`InpEnableHeatmap`, `InpPulseVelocityEmaBars`, `InpPulseVolumeEmaBars`) and
show up on the dashboard as `PULSE`, `VOLUME POC`, `VALUE AREA`, `ORDER FLOW
DELTA (proxy)`, and `DOM IMBALANCE`.

## VX: the Adaptive Flip Engine

`Include/AutopsyX/AdaptiveFlipEngine.mqh` is a gating and sizing layer that
sits between the existing risk check and order entry (`EvaluateEntry()` in
the main `.mq5`). It does not replace `RiskEngine`'s hard kill switch, daily
loss limit, drawdown shutdown, or cooldown logic — those are unchanged and
still fire independently. What VX adds:

- **Probability** — an empirical win rate from the trade history the EA has
  actually recorded, bucketed by market regime when there's enough data in
  that bucket (`InpFlipMinBucketSamples`), falling back to the overall rate
  otherwise. Never a hard-coded assumption.
- **Expected value in R-multiples**, not currency — `EV = P(win)·avgWinR −
  P(loss)·avgLossR`, where 1R is the amount actually risked on that specific
  trade. This is what makes the engine **account-agnostic**: an EV of
  +0.3R means the same thing on a $500 account as a $500,000 one. Trades
  with EV below `InpFlipMinExpectedValueR` are **blocked outright**, not
  just downsized.
- **Account health (0–100)** — blends equity drawdown from peak, margin
  level, the trend in recent vs. overall win rate, and recent execution
  quality (slippage vs. its own established baseline) into one score, all
  from live `AccountInfoDouble()` reads.
- **Risk of ruin** — a practical approximation (not a rigorous closed-form
  proof) of the probability of blowing through the account at the
  configured risk-per-trade, given the measured edge. This is a guardrail
  trigger, not a precise probability claim. Crossing
  `InpFlipMaxRiskOfRuinPct` engages the *existing* `RiskEngine` kill switch
  — VX deliberately does not add a second, competing stop-trading mechanism.
- **Capital states** (`NORMAL` / `CONFIDENT` / `CAUTION` / `RECOVERY`) —
  drive a bounded position-size multiplier. `CONFIDENT` can scale size up
  to `InpFlipConfidentSizeMult`, hard-capped at 1.25x no matter what;
  `CAUTION`/`RECOVERY` scale size down, floored at 0.15x. These bounds
  (`AX_FLIP_SIZE_MULT_MIN`/`MAX` in `Defines.mqh`) are compile-time
  constants — no input or account condition can push sizing outside them.
- **Edge-decay detection** — compares expected value over a recent window
  (`InpFlipRecentWindow` trades) against a longer baseline window
  (`InpFlipBaselineWindow` trades). A meaningful EV drop even amid mixed
  win/loss results (not just a loss streak) forces `RECOVERY` state — this
  catches a strategy quietly degrading, which a simple consecutive-loss
  counter misses.
- **Dynamic position sizing with a hard ceiling** — `RiskEngine::
  LotsForRiskAdaptive()` applies the capital-state multiplier on top of the
  normal risk-per-trade sizing, then re-derives the *implied* risk% of the
  resulting lot size and clamps it to `InpAbsoluteMaxRiskPerTradePct`. This
  ceiling applies even with VX turned off — it's a safety limit, not a
  feature toggle.

**Warm-up is safe by design.** Until `InpFlipMinSampleSize` trades have
closed, the engine reports `warmingUp = true`, never blocks a trade, and
applies no size adjustment (multiplier stays 1.0) — it has no data to
judge on yet, so it stays out of the way rather than guessing. Every closed
trade's flip context (risk amount, R-multiple, capital state, probability,
expected value, size multiplier) is written to the autopsy journal CSV for
after-the-fact review. Set `InpEnableAdaptiveFlip = false` to fall back to
the pre-VX sizing/gating behaviour exactly.

## Dashboard

A lightweight on-chart panel (status, regime, direction, buy/sell score,
confidence, spread, tick velocity, momentum, trades today, win rate, daily
P/L, drawdown, current position, hold time, exit mode, pulse, volume
profile, order-flow delta, DOM imbalance, capital state, account health,
expected value, risk of ruin) refreshes on a timer (`InpDashboardRefreshMs`,
default 500ms) — never on every tick — so it cannot interfere with execution.

## Testing components independently

Run `Scripts/AutopsyX/AutopsyX_SelfTest.mq5` from the Navigator on any chart.
It exercises the symbol profile, tick buffer, microstructure, liquidity,
momentum, risk, adaptive, autopsy, volume profile, order flow, heatmap,
pulse, entry/exit-stop, and the VX Adaptive Flip Engine (warm-up behaviour,
positive- and negative-edge gating, bounded size multipliers, risk-of-ruin
response, and the hard-capped `LotsForRiskAdaptive` sizing) against
synthetic data, and prints PASS/FAIL per assertion — no orders are placed. Full
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
