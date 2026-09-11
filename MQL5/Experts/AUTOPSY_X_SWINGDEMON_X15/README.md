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

## Layout

```
AUTOPSY_X_SWINGDEMON_X15.mq5   - main orchestrator: inputs, OnInit/OnTick/OnTimer/OnTrade/OnDeinit
core/        MarketState, StructureEngine, LiquidityEngine, IPDAEngine, RegimeEngine, BiasEngine, Types
signals/     SetupEngine (setups A-F), ProbabilityEngine, ExpectedValue, SignalFusion
risk/        RiskEngine, ExposureEngine, DrawdownEngine
execution/   BrokerAdapter, ExecutionEngine, PositionManager
intelligence/CorrelationEngine, NewsEngine, SeasonalityEngine, VolatilityEngine
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
- **MANAGEMENT** — partial-close percentages at TP1/TP2.
- **NEWS** — calendar filter on/off, pre-event blackout and post-event confirmation windows (minutes).
- **EXECUTION** — max spread, deviation, retry count.
- **SAFETY** — emergency stop, max trades per day/week, slippage warning threshold.
- **CORRELATION/MACRO** — comma-separated watch-symbol list (only symbols your broker actually offers are used; the rest are silently skipped).
- **WEEKEND** — hold/reduce/close and the Friday server-time hour to apply it.

## Data persistence

- **Trade journal**: `AutopsyX_Journal_<symbol>_<magic>.csv` in the terminal's `MQL5/Files` folder — full forensic record per closed trade, reloaded on every restart to seed the probability/seasonality/diagnostic engines.
- **Drawdown baselines and consecutive-loss counter**: terminal global variables (`AXSD15_<symbol>_<magic>_*`), so a terminal restart doesn't reset the day's risk budget or let a losing streak quietly re-risk.
- **Open positions**: reconstructed from broker position state on `OnInit` (direction/entry/SL/TP/volume) — a restart never duplicates or abandons a position, though the original entry *thesis* text is necessarily generic after a restart (the broker doesn't store it).
