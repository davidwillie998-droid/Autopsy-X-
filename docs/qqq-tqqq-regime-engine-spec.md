# AUTOPSY X QQQ/TQQQ Regime Engine

**Modular Intelligence Layer for Existing Trading Bots**

This is a design specification, recorded as project knowledge alongside `docs/flipdemon-x15-spec.md`. Nothing in this document is implemented yet. It describes a gatekeeper/risk-governor layer for QQQ/TQQQ exposure that sits in front of an existing execution bot (including Flipdemon) rather than replacing it.

---

## 1. Purpose

Build a standalone intelligence module that attaches to an existing trading robot without replacing its current entry, execution, stop-loss, trailing, or trade-management logic.

The engine's job is to answer five questions:

1. What regime is Nasdaq currently in?
2. Is the directional environment bullish, bearish, or neutral?
3. Is the trend efficient enough to justify aggressive exposure?
4. Is volatility expanding or contracting?
5. Should the existing bot operate normally, reduce risk, or stand down?

The engine must **not** blindly multiply position size by 3. TQQQ's 3x objective is daily and path-dependent, so the engine treats leverage as a conditional risk state rather than a permanent multiplier.

---

## 2. Engine Architecture

```
INPUTS
  NASDAQ-100 / NDX, QQQ, TQQQ, VIX, DXY
  US 2Y yield, US 10Y yield, real yields, Fed expectations
  Market breadth, QQQ volume, ATR / realized volatility
  Price structure, session/time, economic-event state
    ↓
DATA NORMALIZATION
    ↓
REGIME CLASSIFIER
    ↓
DIRECTION ENGINE
    ↓
TREND-EFFICIENCY ENGINE
    ↓
VOLATILITY ENGINE
    ↓
MACRO CONFIRMATION ENGINE
    ↓
RISK ENGINE
    ↓
BOT PERMISSION LAYER
    ↓
EXISTING EA
```

The existing EA remains responsible for execution. AUTOPSY X controls whether the EA is allowed to execute and how aggressively it may operate.

---

## 3. Regime Classifier

Six states, using multiple independent measurements rather than one indicator:

- **R1** — Persistent bullish trend
- **R2** — Bullish but unstable
- **R3** — Range / chop
- **R4** — Bearish transition
- **R5** — Persistent bearish trend
- **R6** — Volatility shock

---

## 4. Direction Engine

Calculate `EMA_FAST` (20), `EMA_MEDIUM` (50), `EMA_SLOW` (200).

- **Bullish structure:** `Price > EMA20 > EMA50 > EMA200`
- **Bearish structure:** `Price < EMA20 < EMA50 < EMA200`

Add: higher-high/higher-low detection, lower-high/lower-low detection, 20-day breakout/breakdown state, momentum state.

Generate `DIRECTION_SCORE` in `[-100, +100]`:

| Score | Meaning |
|---|---|
| +70 to +100 | Strong bullish |
| +40 to +69 | Bullish |
| -39 to +39 | Neutral |
| -40 to -69 | Bearish |
| -70 to -100 | Strong bearish |

No single indicator may override the composite score.

---

## 5. Trend-Efficiency Engine

```
TREND_EFFICIENCY = ABS(Net Price Change) / SUM(ABS(Daily Price Changes))
```

Configurable lookback (recommended 10 and 20 days). High efficiency = directional movement with limited backtracking; low efficiency = noisy, rotational market. This is the critical TQQQ filter:

- Strong direction + high efficiency → leverage permission can increase.
- Strong direction + poor efficiency → reduce exposure.
- Strong direction + extreme volatility → potentially stand down.

---

## 6. Volatility Engine

Calculate ATR, ATR percentile, realized volatility, VIX level and change, volatility expansion/compression.

`VOLATILITY_SCORE ∈ { LOW, NORMAL, ELEVATED, HIGH, EXTREME }`

The engine must distinguish **low-vol + trend** from **high-vol + trend** — these are not equivalent trading environments. High volatility does not automatically mean bearish; it means risk conditions have changed.

---

## 7. Volatility Shock Detector

Trigger R6 when several conditions occur simultaneously, e.g.: VIX rapidly expanding; realized volatility above a predefined percentile; QQQ daily movement exceeds an abnormal threshold; ATR expansion exceeds threshold; large price displacement with abnormal volume; multiple risk variables deteriorating simultaneously.

When R6 activates:

```
NEW_TRADES = REDUCE or BLOCK
RISK_MULTIPLIER = 0 to 0.25
LEVERAGE_PERMISSION = FALSE
```

The existing EA must not open new aggressive positions. Existing positions remain under the EA's normal protective management unless a user-configured emergency risk module is enabled.

---

## 8. Macro Confirmation Engine

Evaluate DXY, 2Y yield, 10Y yield, real yields, Fed expectations, major economic releases.

`MACRO_SCORE ∈ [-100, +100]`. The macro score should **confirm** rather than independently dictate the trade — do not automatically reverse the trade merely because one macro variable disagrees.

Example:

- Nasdaq bullish + trend efficient + volatility controlled + macro supportive → **high-confidence bullish state**
- Nasdaq bullish + yields rising sharply + USD strengthening + volatility expanding → **bullish but unstable**

---

## 9. Breadth Engine

Monitor Nasdaq participation: advancing/declining issues, percentage of stocks above moving averages, QQQ breadth, large-cap participation, semiconductor participation.

`BREADTH_SCORE ∈ [-100, +100]`. A bullish move backed by broad participation scores higher than one driven by a narrow group of constituents.

---

## 10. Liquidity / Volume Engine

Monitor QQQ volume, relative volume, volume expansion, price-volume relationship, opening-session participation.

`LIQUIDITY_SCORE`. Avoid aggressive leverage when price moves significantly without adequate participation.

---

## 11. Composite Confidence

Combine `DIRECTION_SCORE`, `TREND_EFFICIENCY_SCORE`, `VOLATILITY_SCORE`, `MACRO_SCORE`, `BREADTH_SCORE`, `LIQUIDITY_SCORE`.

Example weighting (configurable, not hard-coded permanently):

| Component | Weight |
|---|---|
| Direction | 30% |
| Trend efficiency | 20% |
| Volatility | 20% |
| Macro | 15% |
| Breadth | 10% |
| Liquidity | 5% |

Normalize to `CONFIDENCE_SCORE ∈ [0, 100]`.

---

## 12. Regime Decision Matrix

| Regime | Requirements | Permission | Risk multiplier | Aggressive mode |
|---|---|---|---|---|
| **R1** Persistent bullish | Direction strongly bullish, trend efficiency high, volatility low/normal, breadth supportive | TRADE = TRUE | 1.00–1.50 | Permitted |
| **R2** Bullish but unstable | Direction bullish, but volatility elevated / macro conflict / breadth weakening / trend efficiency deteriorating | TRADE = TRUE | 0.50–0.75 | Disabled |
| **R3** Range / chop | Direction near neutral, trend efficiency low, frequent reversals | TRADE = FALSE by default | Optional 0.25 if the EA has a dedicated range strategy | — |
| **R4** Bearish transition | Bullish structure deteriorating, momentum weakening, volatility beginning to expand | TRADE = REDUCED | 0.25–0.50 | Wait for confirmation before aggressive short exposure |
| **R5** Persistent bearish | Direction strongly bearish, trend efficiency high, breadth weak, volatility controlled | TRADE = TRUE | 1.00–1.50 | Permitted only if all safety conditions pass |
| **R6** Volatility shock | Extreme volatility expansion | NEW_TRADES = FALSE | 0 | False — capital-preservation mode |

---

## 13. TQQQ Leverage Model

Never use `POSITION_SIZE × 3` as the primary leverage mechanism. Instead:

```
FINAL_RISK = BASE_RISK
           × REGIME_MULTIPLIER
           × CONFIDENCE_MULTIPLIER
           × VOLATILITY_MULTIPLIER
           × CORRELATION_MULTIPLIER
           × DRAWDOWN_MULTIPLIER
```

Example: `1% × 1.25 (regime) × 0.90 (confidence) × 0.70 (volatility) × 1.00 (drawdown) = 0.7875%`.

This makes the engine adaptive rather than blindly aggressive.

---

## 14. Drawdown Governor

Risk must reduce as account drawdown increases. Example configurable model:

| Drawdown | Risk |
|---|---|
| 0%–3% | Normal |
| 3%–5% | 75% |
| 5%–8% | 50% |
| 8%–10% | 25% |
| 10%+ | Trading halt |

Thresholds are user-configurable. After a halt, require a reset condition before trading resumes.

---

## 15. Correlation Protection

If multiple bots simultaneously trade instruments strongly correlated with Nasdaq (QQQ, TQQQ, NQ, MNQ, US100, NAS100 CFD, tech-heavy equities), they must not be treated as independent positions.

Compute `AGGREGATE_NASDAQ_EXPOSURE`. If it exceeds the configured limit: `NEW_TRADES = REDUCE / BLOCK`. This prevents several bots from unknowingly building one enormous synthetic Nasdaq position.

---

## 16. News / Event Governor

High-impact events: FOMC, CPI, PCE, NFP, GDP, Powell/Fed speeches, major employment releases.

- **Pre-event:** `PRE_EVENT_MODE`, risk multiplier 0.25–0.50.
- **During event:** `NEW_TRADES = FALSE`.
- **After event:** `WAIT_FOR_REPRICE`, then recalculate the entire regime.

Do not assume the initial news spike represents the final market direction.

---

## 17. Entry Permission API

Exposed to the existing EA:

```
ALLOW_LONG, ALLOW_SHORT, ALLOW_NEW_TRADE
REGIME, CONFIDENCE, RISK_MULTIPLIER
VOLATILITY_STATE, TREND_EFFICIENCY
MACRO_SCORE, BREADTH_SCORE, NASDAQ_BIAS
SHOCK_STATE
```

The existing bot should only need to ask: *Can I trade? Which direction? What risk multiplier?*

---

## 18. Example Output

```
REGIME:            R1 PERSISTENT BULLISH
NASDAQ_BIAS:       BULLISH
CONFIDENCE:        87
TREND_EFFICIENCY:  0.78
VOLATILITY:        NORMAL
MACRO:             SUPPORTIVE
BREADTH:           STRONG
LIQUIDITY:         HEALTHY
ALLOW_LONG:        TRUE
ALLOW_SHORT:       FALSE
RISK_MULTIPLIER:   1.25
AGGRESSIVE_MODE:   TRUE
SHOCK_MODE:        FALSE
```

---

## 19. Flipdemon Compatibility

If the existing bot is an aggressive system (e.g. Flipdemon — see `docs/flipdemon-x15-spec.md`), it must **not** bypass the regime engine:

```
FLIPDEMON
  ↓
REQUEST TRADE
  ↓
REGIME ENGINE
  ↓
RISK GOVERNOR
  ↓
PERMISSION
  ↓
EXECUTION
```

Hierarchy: **SAFETY > REGIME > RISK > STRATEGY > ENTRY > EXECUTION**. An aggressive entry system can remain aggressive when conditions justify it, without being permanently exposed to maximum risk. In practice, this means Flipdemon's `FLIP_LONG` / `FLIP_SHORT` outputs (X15 §28) become *requests*, and this regime engine's `ALLOW_LONG` / `ALLOW_SHORT` / `RISK_MULTIPLIER` (§17 above) are the gate they must clear before `EXECUTION`.

---

## 20. Fail-Safe

If external data becomes unavailable (DXY, VIX, QQQ data stale, macro feed, calculation error): `DATA_STATUS = DEGRADED`. Do not increase risk — default `RISK_MULTIPLIER = 0.25`. If critical data remains unavailable: `NEW_TRADES = FALSE`. Never interpret missing data as bullish confirmation.

---

## 21. MT5 Implementation

Reusable MQL5 modules:

```
AutopsyRegimeEngine.mqh
AutopsyVolatilityEngine.mqh
AutopsyMacroEngine.mqh
AutopsyRiskGovernor.mqh
AutopsyCorrelationEngine.mqh
AutopsyEventFilter.mqh
```

Conceptual interface:

```
InitializeRegimeEngine()
UpdateMarketState()
GetRegime()
GetDirection()
GetConfidence()
GetRiskMultiplier()
AllowLong()
AllowShort()
AllowNewTrade()
IsVolatilityShock()
GetAggregateExposure()
ResetRiskGovernor()
```

The existing EA should not need to know how the intelligence is calculated.

---

## 22. Critical Design Rule

The engine must never modify the existing EA's core strategy unless explicitly configured. Default operation:

1. Existing EA generates a signal.
2. AUTOPSY X evaluates market state.
3. AUTOPSY X approves, reduces, or rejects the signal.
4. Existing EA executes according to its normal mechanics.

This makes the engine portable across multiple existing bots.

---

## 23. Logging

Every decision must be logged, e.g.:

```
2026.09.16 15:30
REGIME = R1
BIAS = BULLISH
CONFIDENCE = 84
TREND_EFFICIENCY = 0.74
VIX_STATE = NORMAL
MACRO_SCORE = +61
BREADTH_SCORE = +73
RISK_MULTIPLIER = 1.20
LONG_PERMISSION = TRUE
SHORT_PERMISSION = FALSE
DECISION = APPROVE
```

This creates an audit trail for backtesting and debugging.

---

## 24. Backtest Requirement

Do not optimize only for total profit. Evaluate: net return, maximum drawdown, profit factor, Sharpe, Sortino, Calmar, win rate, average trade, tail loss, worst day, worst week, volatility-adjusted return, time in market, regime-specific performance, long vs. short performance, performance during volatility shocks.

Run in-sample, out-of-sample, walk-forward, Monte Carlo, and parameter-sensitivity tests. The engine is not validated until its performance survives out-of-sample testing.

---

## 25. Final System

```
AUTOPSY X
  ↓
MARKET DATA
  ↓
NASDAQ STATE
  ↓
MACRO STATE
  ↓
VOLATILITY STATE
  ↓
TREND EFFICIENCY
  ↓
BREADTH
  ↓
LIQUIDITY
  ↓
REGIME CLASSIFIER
  ↓
CONFIDENCE ENGINE
  ↓
RISK GOVERNOR
  ↓
CORRELATION GOVERNOR
  ↓
EVENT GOVERNOR
  ↓
TRADE PERMISSION
  ↓
EXISTING BOT
  ↓
EXECUTION
```

The engine is a gatekeeper and adaptive risk layer, not another entry indicator. Its objective is not to predict every Nasdaq move — it is to identify when the existing strategy has a favorable operating environment, when exposure should be reduced, and when trading should stop.

---

## Relationship to what's currently built

Nothing in this spec is implemented. The live Flipdemon HFT Pro panel in `index.html` currently has no regime awareness at all — it trades its VWAP flip signal unconditionally, gated only by the leverage/pyramid/instant-flip toggles a person sets by hand. There is no `ALLOW_LONG`/`ALLOW_SHORT`/`RISK_MULTIPLIER` gate in front of it, no regime classifier, no drawdown governor, no correlation or event governor.

Per §19, the intended relationship once this is built is that Flipdemon's signal becomes a *request* this engine can approve, throttle, or block — not that this engine replaces Flipdemon's entry logic. Building it requires data this project doesn't currently source client-side (VIX, DXY, yields, breadth, macro calendar), so it's a separate data-integration project before it's a code project.
