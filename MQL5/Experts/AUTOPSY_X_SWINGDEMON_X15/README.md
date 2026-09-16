# AUTOPSY X SWINGDEMON X15

Institutional-style adaptive swing-trading Expert Advisor for MetaTrader 5. Native MQL5, no external services required to run the core engine.

## What this is

A real, modular MQL5 codebase implementing the architecture this spec calls for: multi-timeframe structure detection, liquidity mapping, IPDA premium/discount modeling, regime classification, six rule-based setups, a probability/expected-value gate, account-equity-based risk sizing, broker-verified execution, structural position management, a forensic trade journal, and a live dashboard. Every number the EA shows or trades on is computed from real MT5 market/account/broker data at runtime — nothing is hardcoded or invented.

## What this honestly is not (yet)

This was built and reviewed line-by-line for MQL5 correctness in an environment with no MetaEditor/MetaTrader available, so **it has not been compiled or strategy-tested**. Treat first compilation as the start of validation, not the end of it, per the workflow below. Specific scope decisions worth knowing about:

- **Single-symbol-per-chart.** Attach one instance per instrument (start with XAUUSD). Instances sharing the same `InpMagicNumber` are exposure-aware of each other's open positions across symbols (correlation/exposure caps scan *all* open positions with that magic number, not just the current chart's symbol), which is how multi-symbol portfolio risk (section 19/37) is handled without one process juggling every symbol's ticks.
- **Macro/fundamental context (DXY, yields, COT, CPI, NFP, etc.) has no external data feed.** There's no live pull of yields, COT, or macro releases from off-platform sources — only what MT5 itself can supply. Two things are real, not fabricated: (1) the native MT5 Economic Calendar (`CalendarValueHistory`/`CalendarEventById`) drives the news blackout/confirmation windows and degrades cleanly to "no opinion" if the terminal's calendar isn't populated; (2) a lightweight **macro proxy** compares the traded symbol's currency legs against a configurable watch-symbol's own price trend (e.g. USDJPY momentum as a USD-strength proxy for XAUUSD) and only ever nudges confidence up or down — it never flips a structurally-derived direction, and it reports zero reliability (no opinion) when nothing usable is configured. If you have a real macro/COT data source, wire it into `GetMacroContext()` in the main `.mq5` file.
- **Probability/expectancy numbers start neutral.** `ProbabilityEngine` and `SeasonalityEngine` are empirical, built from *this EA's own* closed-trade journal — with zero history they shrink hard to a neutral 50% prior rather than pretending to know anything. They get more meaningful the longer the EA (or a backtest of it) runs.
- **Anti-overfitting / walk-forward / Monte Carlo (section 32) is a testing methodology, not code the EA runs on itself.** Use the MT5 Strategy Tester's own walk-forward and Monte Carlo/optimization tooling against this EA; the EA's `DriftEngine` and `DiagnosticEngine` handle *live* drift detection, which is a different (complementary) thing.

## Sniper entries

The entry model is now the headline feature, not an afterthought. Setups A, B and E no longer fire a market order the instant their structural conditions are met — that's chasing. Instead they compute a precise price and, if the market isn't sitting there right now, place a **resting limit order** and wait:

- **Setup A (sweep + MSS)** computes the real impulse leg behind the structural break (`StructureEngine::GetImpulseLeg` — the origin swing that was swept, and the furthest price reached since) and retraces it to the **OTE zone** (62–79% by default, `InpOTEFibNear`/`InpOTEFibFar`). The limit sits at the shallow (62%) bound unless a real order block or fair value gap overlaps the zone, in which case the price snaps to that structure's edge instead — Fibonacci math and real structure agreeing is the whole point of a sniper entry, not a coincidence to ignore. If price is already sitting inside the OTE band right now, it enters at market (there's nothing to wait for); if price already blew *past* the zone toward invalidation, the setup is skipped outright rather than chasing.
- **Setup B (HTF continuation)** and **Setup E (HTF imbalance)** enter at the *far edge* of the order block / fair value gap — the best price the zone can realistically offer — rather than wherever price happened to be when the lower-timeframe confirmation candle printed.
- **Invalidation, not just a stop-loss.** Every sniper order carries an `invalidationPrice` distinct from (and tighter than) its eventual stop-loss: if price closes back through the setup's own origin *before the order ever fills*, the order is pulled immediately (`PendingOrderManager`) — no chasing a thesis that's already dead. An unfilled order also expires after `InpLimitOrderExpiryMinutes` (default 3 hours): no fill in that window means the shot is gone.
- **One order at a time.** `InpMaxConcurrentSniperOrders` (default 1) means the EA aims and waits rather than spraying several resting orders across setups. A new candidate is skipped entirely while one is already working.
- **Precision is scored, not just tolerated.** A confluent entry (Fibonacci zone *and* a real order block/FVG agreeing) scores materially higher in `SignalFusion` than a bare Fib level, and pushes the setup toward A/A+ rather than B.
- Setups C, D and F stay confirmation/retest-based (they already require price to prove itself before entering) rather than being forced into the limit-order model.

On the dashboard, a resting sniper order shows its setup, exact price, distance in points, and time to expiry — distinct from an open position, since "waiting for the shot" and "in the trade" are different states worth seeing separately.

## Order flow, volume profile, footprint, and DOM heatmap

This is real tick-and-book data from MT5's actual APIs (`CopyTicksRange`, `MarketBookAdd`/`OnBookEvent`), not a simulation — but it comes with the single biggest honesty caveat in this codebase, and it's worth reading before trusting any of these numbers:

**Most retail FX/CFD brokers report quote ticks (bid/ask), not real trade prints with a buy/sell side.** A genuine "footprint" needs to know which side of the tape was the aggressor on every print — real exchanges and some ECN/futures-style CFD feeds tag this (`TICK_FLAG_BUY`/`TICK_FLAG_SELL` in `MqlTick.flags`), but plain spot FX usually doesn't. `OrderFlowEngine` checks for these flags on every refresh and uses them when present; when they're absent it falls back to the **tick rule** (an uptick counts as buy pressure, a downtick as sell pressure) — directionally useful, but an approximation, not a real trade-and-sales feed. `HasRealTradeFlags()` and `HasRealVolume()` report which mode built the current numbers, and the dashboard marks approximated pulse readings `[approx]` rather than presenting them as certain.

What's built, all from `intelligence/OrderFlowEngine.mqh`:

- **Volume profile** — a real tick-price histogram (or, if tick history is too sparse/unavailable, an honest bar-distributed approximation) over a rolling lookback window (`InpVolumeProfileLookbackHours`, default 6h). **POC** (point of control) and a 70%-**value area** (VAH/VAL) are computed with the standard expand-from-POC algorithm.
- **Cumulative delta** — running buy volume minus sell volume over the window.
- **Delta divergence** — price trended one way over the last N completed H1 bars while net delta over that same window disagreed (a real order-flow tell, not a lagging price-pattern guess).
- **Absorption** — a completed bar with unusually large volume that still failed to move price much versus its recent range; the delta's sign says which side got absorbed.
- **Pulse** — a 0-100 tape-tempo score blending real tick-arrival acceleration (when tick data is available) with ATR-relative price velocity; classified Quiet/Normal/Elevated/Surging.
- **DOM heatmap** — Level-2 book via `MarketBookAdd`/`OnBookEvent`, when the broker actually offers it. `MarketBookAdd` succeeding is *not* proof of real data — plenty of brokers accept the subscription for a spot symbol and then never deliver a populated book — so `CHeatmapEngine::Available()` also checks that book updates have actually arrived recently (30s staleness window) before reporting DOM as usable. When it isn't, the dashboard says so plainly rather than showing stale or empty numbers as if they meant something.

**Wired into decisions, not just displayed:** `SignalFusion` now carries an order-flow evidence component (10% weight, rebalanced from volatility and correlation to make room) — delta agreeing with the candidate's direction, a confirming divergence, absorption on the right side, trading inside the value area, and a genuine resting DOM wall backing the entry all raise it; none of it can override a structurally-derived signal, and it contributes a neutral 50 (no effect) whenever the underlying data isn't available. This is computed per-candidate in `ComputeOrderFlowScore()` in the main `.mq5` file.

**Operational notes:** `CopyTicksRange` is real work, not a free call — it's throttled to run at most once per `InpOrderFlowRefreshSeconds` (default 90s), keep `InpVolumeProfileLookbackHours` modest, and `InpMaxTicksAnalyzed` caps how much of a very busy session gets processed (falling back to the most recent slice rather than blocking). The very first call on a symbol you haven't had charted before may be slow while the terminal fetches tick history from the broker — this is a real MT5 characteristic, not a bug in this code. Toggle the whole subsystem off with `InpOrderFlowEnabled`/`InpHeatmapEnabled` if you'd rather not pay this cost, or on a symbol where the data quality is too poor to be useful (both degrade to neutral automatically either way).

## Live vs. demo execution

Demo servers are usually forgiving: tight constant spread, instant fills, permissive filling modes, no real margin pressure. Live servers aren't, and this EA treats that as the normal case rather than an edge case:

- **Filling-mode fallback.** `BrokerAdapter` builds a try-order of every filling mode the symbol advertises (FOK/IOC/RETURN). If a live send comes back `TRADE_RETCODE_INVALID_FILL` — a rejection that's rare on demo but real on many ECN/STP live venues, including for symbols whose advertised support flags turn out to be wrong — `ExecutionEngine` swaps to the next mode and resends the *same* price rather than treating it as a generic rejection. This doesn't cost a requote-retry slot.
- **Partial fills are handled correctly, not misreported as failures.** The old version of this verified the opened position against the *requested* volume; a genuine partial fill (far more common live than on demo) would then fail verification and the EA would report the trade as failed — while a real, unmanaged position sat open on the account. `ExecutionEngine.OpenMarket` now reads the actual filled volume back from the trade result and verifies against *that*, and the resulting `AXTradeThesis` sizes its risk/partial-close math off the real fill, not the ask.
- **Adaptive deviation.** `InpDeviationPoints` is a floor, not a fixed value — the actual deviation passed to the broker scales up with the currently-quoted spread (capped at 5x the input) so a live account's normally-wider spread doesn't manufacture rejections that a demo account, quoting near-zero spread, would never hit.
- **Relative spread-spike filter**, on top of the absolute `InpMaxSpreadPoints` cap: `BrokerAdapter` keeps a rolling average of the spread this account has actually seen, and `InpSpreadSpikeMultiple` blocks new entries when the current spread blows out past that average (news, rollover, thin liquidity) — a single static cap can't tell a genuine spike apart from a broker that just always quotes wide.
- **Pre-trade margin check.** `OrderCalcMargin` is called before every send; an order that would eat into free margin (95% threshold, so it never trades right up to a margin call) is refused before it ever reaches the broker, rather than discovered as a live-only rejection.
- **Aggregate volume-limit check.** Some brokers enforce `SYMBOL_VOLUME_LIMIT` (a per-symbol cap across all your positions) that demo servers often don't bother with; the EA checks it before sending.
- **Execution-quality feedback loop, fed by real fills.** Slippage and order-round-trip latency are logged from this account's own actual trades (not simulated), and once there are 10+ real fills the expected-value calculation uses *that* observed slippage instead of a static guess — so live costs get baked into the EV gate as they're discovered, live latency and slippage degradation both suspend new entries (`DiagnosticEngine`, `InpSlippageWarnPoints` / `InpLatencyWarnMs`), and current spread/average spread, slippage, latency, partial-fill count, and filling-mode-fallback count are all visible on the live dashboard.

None of this is simulated in a way that would show up identically in a backtest — the Strategy Tester's default execution model doesn't reproduce filling-mode rejections, real partial fills, or live spread-spike behavior particularly faithfully. Treat a green backtest as necessary, not sufficient, and watch the dashboard's execution section (and the account's own trade history) during the demo-account phase of the validation workflow below — that's where these numbers become real.

## Adaptive Flip Engine

Every setup so far (A-F, and now G below) used to hit a hard wall the instant an opposing position was already open: `ExposureEngine::HasOpposingPosition()` returning true was an outright refusal, full stop, regardless of how much better the new signal was. `risk/AdaptiveFlipEngine.mqh` replaces that wall with a judgment call — off by default (`InpFlipEngineEnabled=false`), so the EA's behavior is byte-for-byte identical to before unless you turn it on.

When enabled, a new signal that opposes an existing position must clear every one of the following before the EA will close that position and take the new one, in `CAdaptiveFlipEngine::EvaluateFlip()`:

- **Confirmed regime change.** The regime attached to the new signal must differ from the regime the open position was entered under — same-regime opposition looks like chop, not a real reversal.
- **Minimum confidence improvement** (`InpFlipMinConfidenceDelta`, default 12 points) over the open position's original fused confidence.
- **Minimum expected-value improvement** (`InpFlipMinEvImprovementR`, default 0.15R) over the open position's original expected R.
- **Execution quality.** If this account's own observed average slippage (once there are enough real fills to trust it) exceeds `InpFlipMaxExecSlippagePoints`, a flip is refused — closing a real position to chase a new one isn't worth it on a feed that can't fill cleanly.
- **Risk-of-ruin.** A fixed-fractional risk-of-ruin approximation (classic gambler's-ruin-with-edge form — see the method's own comment in `AdaptiveFlipEngine.mqh` for the exact formula and its derivation) computed from *this account's own* empirical win rate and average win/loss R from the trade journal. Below 15 closed trades it degrades to a conservative flat estimate rather than pretending to know the account's edge. A flip is refused above `InpFlipMaxRiskOfRuinPercent` (default 5%).
- **Capital state.** A 5-state machine — `Normal → Cautious → Recovery → Defensive → Locked` — driven by daily/weekly drawdown, consecutive losses, risk-of-ruin, and `DriftEngine`'s statistical significance flag. Escalation (risk rising) is immediate; de-escalation steps down exactly one level per re-evaluation, and `Defensive`/`Locked` must pass back through `Recovery` before regaining full-size risk — one good trade can't undo a real breach. `Locked` blocks flips (and, separately, Setup G entries) outright. Every other state scales the new trade's risk% by a multiplier (`Normal`=1.0, `Cautious`=0.7, `Recovery`=0.4, `Defensive`=0.25) rather than an all-or-nothing switch.
- **Hard limits**: a cooldown (`InpFlipCooldownMinutes`), and daily/weekly flip caps (`InpMaxFlipsPerDay`/`InpMaxFlipsPerWeek`) — all persisted through terminal restarts via global variables, same pattern as `DrawdownEngine`.

All of this is account-agnostic by construction: every threshold is a percentage, an R-multiple, or a point count derived from *this* account's live equity/journal — never a fixed dollar amount — so the same engine is correct on a $500 account and a $500,000 one. This also fulfils the original spec's section-17 "Swing Flip Engine" requirement, which the initial build never actually implemented.

The dashboard's new **ADAPTIVE FLIP ENGINE** panel shows the live capital state, risk-of-ruin%, edge-health score, and today's/this-week's flip counts regardless of whether flipping itself is enabled — so you can watch the account-health machinery working even with `InpFlipEngineEnabled=false`.

## VWAP trend/flip (Setup G)

Added per Zarattini & Aziz, *"VWAP: The Holy Grail for Day Trading Systems"* (SSRN 4631351, 2023) — a real academic backtest of trading the session VWAP as a trend/flip signal. Off by default (`InpVWAPSetupEnabled=false`); enabling it adds a **new, independent trading mode** alongside setups A-F, not a replacement for them.

- **VWAP itself is real**, computed in `intelligence/VWAPEngine.mqh` from `CopyRates(PERIOD_M1, ...)` since the configured session start (`InpVWAPSessionStartHour`) — `Sum(HLC3 × Volume) / Sum(Volume)` over every *completed* M1 bar, using real exchange volume (`SYMBOL_VOLUME_REAL`) when the broker provides it and falling back honestly to tick volume otherwise (`UsedRealVolume()` reports which).
- **The paper's actual trigger, reproduced faithfully**: a direction is only trusted when the most recently *completed* M1 candle **closes** beyond VWAP — a wick through it intrabar is explicitly not a signal, in the paper or here (`CVWAPEngine::LastCompletedBarClosedAbove/Below`).
- **Always-in-market by design.** Once VWAP data is valid, `CSetupEngine::EvaluateVWAPFlip()` always resolves to a side (long above, short below) — there's no "no trade" state the way A-F have one, which is why this runs on its own M1 cadence (`TryEnterOrFlipVWAP()` in the main file), completely separate from the H1-gated `TryEnterTrade()` pipeline for setups A-F.
- **The real exit is the flip itself, or the session close** — not a fixed take-profit. A confirmed VWAP recross closes the current position and opens the opposite one in the same motion (`TryEnterOrFlipVWAP`); `InpVWAPFlattenAtSessionEnd`/`InpVWAPSessionEndHour` flattens any open VWAP position at the configured server hour regardless, reproducing the paper's no-overnight rule. `ManageVWAPPosition()` handles only this — Setup G positions bypass `PositionManager`'s phase machine entirely, since phases (partials/breakeven/trailing) don't apply to a strategy with no fixed TP.
- **Position sizing deliberately does NOT reproduce the paper's own methodology.** The paper backtests at up to 100% of equity per trade, appropriate for isolated academic backtesting, not for a live account. Every VWAP trade here is sized through the same `RiskEngine` as setups A-F, off `InpVWAPRiskPercent` (independent dial from `InpRiskPercentDefault`) with the stop set at VWAP itself (plus a small ATR buffer) — capital preservation takes priority over reproducing the paper's raw numbers.
- **A VWAP flip still respects the Adaptive Flip Engine's capital-state machine** (a `Locked` account blocks new VWAP entries and flips too, and risk scales by the same multiplier as everything else) but deliberately skips `EvaluateFlip()`'s confidence-delta/EV-improvement/regime-change/cooldown checks — those exist to judge "should I abandon my *swing* thesis for a different one," and Setup G's entire mechanic *is* flipping on every confirmed VWAP recross. Gating it on swing-specific criteria would silently break the paper's actual method.
- Recovery after a restart identifies an open Setup G position the same way every other setup is identified in the trade journal — a tag in the position's own broker comment (`AXSD15-G: VWAP Trend/Flip`) — since MT5 doesn't let you store a custom enum on a position across restarts.

## Layout

```
AUTOPSY_X_SWINGDEMON_X15.mq5   - main orchestrator: inputs, OnInit/OnTick/OnTimer/OnTrade/OnDeinit
core/        MarketState, StructureEngine, LiquidityEngine, IPDAEngine, RegimeEngine, BiasEngine, HeatmapEngine, Types
signals/     SetupEngine (setups A-F, plus G: VWAP Trend/Flip), ProbabilityEngine, ExpectedValue, SignalFusion
risk/        RiskEngine, ExposureEngine, DrawdownEngine, AdaptiveFlipEngine
execution/   BrokerAdapter, ExecutionEngine, PositionManager, PendingOrderManager
intelligence/CorrelationEngine, NewsEngine, SeasonalityEngine, VolatilityEngine, OrderFlowEngine, VWAPEngine
autopsy/     TradeJournal, DiagnosticEngine, DriftEngine
ui/          Dashboard
```

Every `.mqh` has `#ifndef/#define/#endif` include guards — the include graph is deep enough (most modules pull in `core/Types.mqh` and `core/MarketState.mqh` transitively) that duplicate inclusion would otherwise fail compilation.

## Installing

1. Copy the whole `AUTOPSY_X_SWINGDEMON_X15` folder into `<Terminal Data Folder>/MQL5/Experts/`.
2. Open `AUTOPSY_X_SWINGDEMON_X15.mq5` in MetaEditor and compile (F7).
3. Attach to a chart (XAUUSD H1 recommended as the setup timeframe; the EA reads M1 through MN1 internally regardless of the chart's own timeframe).
4. Enable AutoTrading. Review inputs — defaults are conservative (0.5% base risk, A/A+ only, 3 max positions, daily/weekly/monthly drawdown kill-switches).

## Build/validation workflow to actually run

This is the workflow from the spec's section 44 — it hasn't been executed here (no MetaEditor in this environment), so do this before trusting the EA with real money:

1. **Compile.** Fix every error MetaEditor reports before touching anything else. Re-read this codebase's logic against any error — don't paper over a type mismatch by casting blindly.
2. **Clear the warnings you reasonably can.** Some (e.g. unused private-member warnings on engine pointers stored for future use) are harmless; don't chase every last one blindly.
3. **Static review.** Read `AUTOPSY_X_SWINGDEMON_X15.mq5` top to bottom against the module it calls — confirm the wiring in `OnInit`/`TryEnterTrade` matches what you actually want live.
4. **Strategy Tester, visual mode, single symbol.** Watch it reject far more than it enters — "NO TRADE" is meant to be the default outcome. Confirm SL/TP/partials/breakeven/trailing behave as expected against real tick data.
5. **Strategy Tester, "Every tick based on real ticks", multi-year, walk-forward.** This is where overfitting shows up.
6. **Monte Carlo / parameter perturbation / spread & slippage stress.** Nudge `InpDeviationPoints`, `InpMaxSpreadPoints`, and the risk inputs and confirm nothing breaks or blows past the drawdown caps.
7. **Demo account, real ticks, weeks not days**, before ever moving to live.
8. **Final live check:** confirm `InpMagicNumber` is unique per deployed instance/symbol, `InpEnableLiveTrading` is true, and the failsafes (`CheckFailsafes` in the main file) are tuned to your broker's real spread/margin behavior.

## Key configuration groups (all in the main `.mq5`, no source edits needed)

- **CORE** — magic number, live-trading master switch, dashboard toggle.
- **RISK** — per-trade %, hard caps on per-trade/total-open/correlated risk, max positions, daily/weekly/monthly drawdown kill-switches, max consecutive losses.
- **ENTRY** — minimum confidence, minimum R:R, minimum expected value (in R), whether Grade B setups may trade live (A/A+ only by default).
- **SNIPER ENTRY** — OTE Fibonacci bounds (`InpOTEFibNear`/`InpOTEFibFar`), how long a resting limit order waits before expiring, and how many may rest at once (default 1).
- **MANAGEMENT** — partial-close percentages at TP1/TP2.
- **NEWS** — calendar filter on/off, pre-event blackout and post-event confirmation windows (minutes).
- **EXECUTION** — max spread (absolute), spread-spike multiple (relative to this account's own rolling average), deviation floor, retry count.
- **SAFETY** — emergency stop, max trades per day/week, slippage and latency warning thresholds.
- **CORRELATION/MACRO** — comma-separated watch-symbol list (only symbols your broker actually offers are used; the rest are silently skipped).
- **ORDER FLOW / VOLUME PROFILE / HEATMAP** — on/off for the tick-based order-flow engine and the DOM heatmap, volume-profile lookback window/bucket count, refresh throttle, and the tick-count safety cap.
- **WEEKEND** — hold/reduce/close and the Friday server-time hour to apply it.
- **VWAP TREND (SETUP G)** — on/off (default off), session-start hour, independent risk% dial, session-end flatten on/off and hour.
- **ADAPTIVE FLIP ENGINE** — on/off (default off), daily/weekly flip caps, cooldown, minimum confidence-delta/EV-improvement to justify a flip, max risk-of-ruin%, the equity-drawdown% treated as "ruin," and the execution-slippage ceiling above which a flip is refused.

## Data persistence

- **Trade journal**: `AutopsyX_Journal_<symbol>_<magic>.csv` in the terminal's `MQL5/Files` folder — full forensic record per closed trade, reloaded on every restart to seed the probability/seasonality/diagnostic engines.
- **Drawdown baselines and consecutive-loss counter**: terminal global variables (`AXSD15_<symbol>_<magic>_*`), so a terminal restart doesn't reset the day's risk budget or let a losing streak quietly re-risk.
- **Open positions**: reconstructed from broker position state on `OnInit` (direction/entry/SL/TP/volume) — a restart never duplicates or abandons a position, though the original entry *thesis* text is necessarily generic after a restart (the broker doesn't store it). An open Setup G (VWAP) position is re-identified the same way via its `AXSD15-G: VWAP Trend/Flip` order comment.
- **Adaptive Flip Engine state**: capital state, and today's/this-week's flip counts, persisted through terminal restarts via global variables (`AXSD15_FLIP_<symbol>_<magic>_*`), same pattern as the drawdown engine.
