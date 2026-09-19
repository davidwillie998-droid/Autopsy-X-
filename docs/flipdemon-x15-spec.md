# AUTOPSY X FLIPDEMON HFT PRO X15

**Adaptive VWAP Liquidity Reversal & High-Risk Execution Engine**

This is the design specification for the next iteration of the Flipdemon module. It supersedes the scope of the current in-browser Flipdemon HFT Pro panel (`index.html`, the "Flipdemon HFT Pro" section), which implements only the base VWAP Trend Trading rules plus three risk amplifiers (leverage, pyramiding, instant flip). X15 is a considerably larger architecture — a full state-machine execution engine intended to run as an add-on layer inside the existing MT5 EA, not as a browser-side signal panel. Nothing described here is implemented yet; this document exists so the architecture is recorded and can be built out incrementally against a real design instead of from memory.

## System ID

- **Name:** AUTOPSY X FLIPDEMON HFT PRO X15
- **Role:** Adaptive high-frequency/high-risk execution module
- **Parent System:** Existing AUTOPSY X / MT5 EA
- **Primary Instrument:** XAUUSD
- **Execution Platform:** MetaTrader 5
- **Architecture:** Add-on module, not a replacement EA
- **Primary Objective:** Detect short-term directional imbalance, identify when that imbalance is failing, flip directional bias when sufficient evidence appears, and manage the resulting position dynamically.

---

## 1. Core Mission

Operate inside the existing automated trading system.

- Do not rebuild the existing EA.
- Do not duplicate its core functionality.
- Do not create unnecessary external connectors.

Instead, integrate as an intelligent adaptive layer capable of:

- reading the existing EA's market state
- calculating VWAP intelligence
- detecting directional persistence
- identifying liquidity events
- detecting displacement
- identifying structural failure
- detecting VWAP reclaim/failure
- determining when the current directional thesis is weakening
- triggering a controlled directional flip
- dynamically managing entries, exits and exposure
- protecting the account during abnormal market conditions

The engine must behave as a state machine, not as a collection of isolated indicators.

---

## 2. Primary Philosophy

Never treat a single event as sufficient evidence.

- A VWAP cross alone is NOT a flip.
- A liquidity sweep alone is NOT a flip.
- An FVG alone is NOT a flip.
- A candle spike alone is NOT a flip.
- A structure break alone is NOT automatically a flip.

The engine should seek confluence between independent pieces of evidence. The fundamental question is:

> "Has the market demonstrated enough evidence that the existing directional state is no longer statistically or structurally valid?"

If YES: **WEAKEN → INVALIDATE → CONFIRM → FLIP**

If NO: **HOLD CURRENT STATE**

---

## 3. VWAP Intelligence Core

Calculate session VWAP using:

```
VWAP = Σ(Price × Volume) / ΣVolume
```

Where possible, use `Price = (High + Low + Close) / 3`.

The engine must distinguish:

- real exchange volume
- broker volume
- tick volume
- unavailable volume

For XAUUSD MT5 environments, do not assume broker tick volume represents centralized institutional volume. VWAP therefore becomes an intraday state reference, not proof of institutional positioning.

---

## 4. VWAP State Model

| State | Name | Description |
|---|---|---|
| A | Strong Bullish | Price above VWAP; VWAP rising; repeated acceptance above VWAP; bullish displacement, structure, and liquidity behavior; limited adverse VWAP crossings. |
| B | Bullish | Price remains above VWAP but directional strength is deteriorating. |
| C | Equilibrium | Repeated VWAP crossings, compressed distance, weak displacement, conflicting structure, poor directional persistence. **Action: reduce aggression / possible no-trade.** |
| D | Bearish | Price below VWAP with developing bearish confirmation. |
| E | Strong Bearish | Price below VWAP; VWAP falling; repeated acceptance below VWAP; bearish displacement, structure, and liquidity behavior. |

---

## 5. Flipdemon State Machine

The engine must maintain a persistent directional state:

```
NEUTRAL
BULLISH
BULLISH_WEAKENING
BULLISH_INVALIDATED
FLIP_TO_BEARISH
BEARISH
BEARISH_WEAKENING
BEARISH_INVALIDATED
FLIP_TO_BULLISH
EMERGENCY_EXIT
LOCKED
```

Never jump directly from `BULLISH → SHORT` unless the required confirmation stack has been satisfied.

Preferred transition (bearish flip):

```
BULLISH
  ↓
BULLISH_WEAKENING
  ↓
LIQUIDITY FAILURE
  ↓
BEARISH DISPLACEMENT
  ↓
VWAP FAILURE
  ↓
STRUCTURE CONFIRMATION
  ↓
FLIP TO BEARISH
```

Reverse the logic for bullish flips.

---

## 6. Flip Trigger Engine (Bearish)

A potential bearish flip can be generated when multiple conditions align:

- **VWAP:** price loses VWAP; VWAP slope weakens or turns bearish; failed reclaim of VWAP.
- **Liquidity** (one or more): buy-side liquidity sweep; previous-high sweep; equal-high raid; session-high raid; external liquidity rejection.
- **Structure** (one or more): bearish MSS; bearish BOS; lower-high formation; failure of bullish continuation.
- **Displacement:** require meaningful bearish displacement relative to recent volatility.
- **Location:** prefer flips occurring near meaningful liquidity or structural levels.
- **Execution:** only authorize the flip when execution conditions remain acceptable.

---

## 7. Bullish Flip

Mirror the bearish logic. A potential bullish flip requires evidence such as:

- price reclaiming VWAP
- VWAP stabilization or bullish slope
- failed bearish continuation
- sell-side liquidity sweep
- previous-low/session-low raid
- bullish displacement
- bullish MSS/BOS
- FVG formation or valid imbalance
- acceptable spread and volatility

```
BEARISH
  → WEAKENING
  → LIQUIDITY FAILURE
  → BULLISH DISPLACEMENT
  → VWAP RECLAIM
  → STRUCTURE CONFIRMATION
  → FLIP LONG
```

---

## 8. Flip Confidence Score

A normalized 0–100 score. Suggested starting weights (engineering starting points, **not validated statistical optimums** — do not claim they produce a profitable system without testing):

| Component | Weight |
|---|---|
| VWAP State | 15% |
| VWAP Slope | 10% |
| VWAP Persistence | 10% |
| Liquidity Event | 15% |
| Market Structure | 15% |
| Displacement | 15% |
| Volatility | 5% |
| Session | 5% |
| Execution Quality | 5% |
| Macro / Event Filter | 5% |

**Execution Quality standard.** "Execution Quality" here should mean something specific, not a vague sense of "did the fill look okay." Patnaik & Thomas, *Profitability of Trading Strategies on High-Frequency Data, with Trading Costs* (SSRN 568363, 2004), is the standard this component is trying to meet: rather than assuming a trade fills at the quoted bid/ask, they reconstruct the actual fill price a given order size would get by walking the real limit-order-book depth, defining impact cost as `IC = 100 × [P_actual / (P_benchmark × Q) − 1]` against a mid-of-extremes benchmark price (their eq. 2–4). Applied here: before this component can output anything better than a guess, it needs the same thing — the actual depth-weighted fill price for the position size Flipdemon is about to take, not the last quoted bid/ask, because impact cost is non-proportional to size and a small paper backtest understates what a live account will actually pay to get in and out. Until MT5 order-book depth (not just top-of-book bid/ask) is wired in, this component should be treated as `UNAVAILABLE` per the §20 fail-safe rule, not defaulted to a passing score.

Suggested interpretation (thresholds must remain configurable):

| Score | Meaning |
|---|---|
| 0–39 | No flip |
| 40–54 | Watch |
| 55–69 | Possible flip |
| 70–79 | High-conviction flip candidate |
| 80–100 | Flip authorization zone |

---

## 9. Anti-Chop Engine (mandatory)

If price repeatedly crosses VWAP without meaningful displacement, set `VWAP_CHOP = TRUE`. Then:

- reduce entries
- reject rapid reversals
- increase confirmation requirements
- prevent flip-flop trading
- impose cooldown
- wait for directional expansion

The engine must never attempt to recover losses by increasing trade frequency.

---

## 10. HFT Microstructure Engine

Monitor: current spread, spread expansion, tick activity, candle range, range expansion, short-term volatility, acceleration, impulse strength, retracement depth, execution latency where measurable.

`MICROSTRUCTURE_STATE ∈ { QUIET, NORMAL, EXPANDING, FAST, EXTREME, UNSAFE }`

If `MICROSTRUCTURE_STATE = UNSAFE`, the engine must block new positions.

---

## 11. ICT / SMC Integration

The engine may use: liquidity sweeps, MSS, BOS, FVG, order blocks, premium/discount, dealing range, internal liquidity, external liquidity, session highs/lows, previous day high/low, equal highs/lows.

Do not allow terminology to substitute for measurable rules — every concept must eventually resolve into observable market data.

---

## 12. Entry Architecture

Do not enter simply because a flip has been detected. Preferred sequence:

```
FLIP DETECTED
  ↓
CONFIRMATION
  ↓
RETRACEMENT / EXECUTION LOCATION
  ↓
EXECUTION CHECK
  ↓
ORDER
```

Configurable entry modes:

- **Aggressive** — enter immediately after confirmed displacement.
- **Balanced** — wait for retracement.
- **Precision** — wait for retracement into an FVG/order-block/discount-premium location.

---

## 13. High-Risk Engine

High risk does not mean unlimited risk. Risk parameters must be external inputs:

```
RiskPerTrade
MaxDailyRisk
MaxOpenPositions
MaxConsecutiveLosses
MaxSpread
MaxSlippage
CooldownSeconds
MaxExposure
EmergencyDrawdown
FlipCooldown
NewsProtection
```

Never hard-code dangerous leverage or account-destruction logic. Never use `Martingale = TRUE`, unlimited lot multiplication, or a loss-recovery multiplier unless deliberately implemented as a separate, clearly-labeled research-only module. Default: `MARTINGALE = OFF`.

---

## 14. Dynamic Position Sizing

Position size must consider: account equity, configured risk, stop distance, tick value, contract size, symbol specification, broker minimum/maximum lot, lot step. Do not calculate lot size from a fixed pip assumption — for XAUUSD, read the actual symbol properties from MT5.

---

## 15. Dynamic Stop Engine

Stops may be derived from: recent structure, liquidity invalidation, volatility, ATR, swing point, displacement structure. The stop must have a clear invalidation reason. Never move the stop farther from the invalidation point simply to avoid realizing a loss.

---

## 16. Rapid Management

After entry, monitor: MFE, MAE, momentum, VWAP position, structure, liquidity, spread, volatility, flip probability.

Possible actions: `HOLD, REDUCE, MOVE_TO_BREAKEVEN, TRAIL, PARTIAL_EXIT, FULL_EXIT, FLIP, EMERGENCY_EXIT`.

The management engine must be independent from the original entry thesis — once the market changes, management changes.

---

## 17. Flip Execution Rule

Never flip repeatedly within the same market noise cycle. Implement:

```
MIN_FLIP_DISTANCE
MIN_FLIP_SCORE
FLIP_COOLDOWN
MAX_FLIPS_PER_SESSION
MAX_FLIPS_PER_DAY
```

```
LONG
  ↓
LONG INVALIDATED
  ↓
SHORT CONFIRMED
  ↓
CLOSE LONG
  ↓
EXECUTION CHECK
  ↓
OPEN SHORT
```

Do not maintain both directions simultaneously unless explicitly configured as a hedging mode.

---

## 18. News / Extreme Volatility Protection

For XAUUSD, abnormal volatility can make an HFT strategy behave completely differently. If reliable event data is available, detect CPI, NFP, FOMC, PCE, major central-bank decisions, and major US macro releases.

Also detect market-based abnormal conditions independently: extreme spread, abnormal candle range, extreme tick acceleration, execution rejection, abnormal slippage.

When conditions exceed configured limits: `NEW ENTRY = BLOCKED`. Existing positions may be managed under emergency rules. Never invent economic events when event data is unavailable.

---

## 19. Execution Safety

Before every order, check: symbol, market open, spread, lot size, margin, stop distance, trade mode, slippage, exposure, daily loss, cooldown, news filter, duplicate position.

If any mandatory check fails: `ORDER = REJECTED`. Record the reason.

The "slippage" check is the same execution-quality question as §8's Execution Quality component, and should be held to the same standard (Patnaik & Thomas, SSRN 568363 — see the Execution Quality note above): a slippage check that only compares the fill against the last quoted price is checking the wrong thing. The paper's point is that the *expected* cost of a trade of a given size is a function of order-book depth, not the quote — so the check that matters is whether the fill was consistent with the depth-weighted impact cost the position size implied, not merely "close to the last tick." A slippage check with no depth data behind it is a weaker check than it looks.

---

## 20. Performance Telemetry

Every trade must record: timestamp, symbol, direction, VWAP, VWAP distance, VWAP slope, VWAP state, liquidity event, structure state, displacement, entry, stop, target, spread, slippage, risk, flip score, exit reason, MFE, MAE, profit/loss, holding time.

This data becomes the foundation for future optimization.

---

## 21. Self-Diagnostic Engine

The system must distinguish between: signal failure, execution failure, market regime failure, parameter failure, data failure, broker failure.

Do not automatically blame the strategy for an execution problem. Do not automatically optimize parameters after a small losing sample.

---

## 22. Adaptive Regime Engine

`MARKET_REGIME ∈ { TRENDING, MEAN_REVERTING, TRANSITION, HIGH_VOLATILITY, LOW_VOLATILITY, VWAP_CHOP, NEWS, UNSAFE }`

| Regime | Recommended behavior |
|---|---|
| Trending | Allow continuation and selective flips. |
| Mean-reverting | Increase confirmation requirements. |
| Transition | Allow only high-quality reversal structures. |
| High volatility | Reduce exposure or require stronger confirmation. |
| VWAP chop | Block aggressive flipping. |
| News | Apply configured event rules. |
| Unsafe | No new trades. |

---

## 23. AUTOPSY X Integration

```
AUTOPSY X
├── MARKET DATA
├── MACRO INTELLIGENCE
├── VWAP ENGINE
├── LIQUIDITY ENGINE
├── ICT / STRUCTURE ENGINE
├── MICROSTRUCTURE ENGINE
├── FLIPDEMON X15
│   ├── State Detection
│   ├── Flip Detection
│   ├── Confirmation
│   └── Execution
├── RISK ENGINE
└── MT5 EXECUTION
```

The Flipdemon module should expose a clean interface to the existing EA, conceptually:

```
GetVWAPState()
GetMarketRegime()
GetFlipScore()
GetDirectionalBias()
GetFlipSignal()
GetRiskState()
GetExecutionPermission()
GetExitSignal()
```

---

## 24. Master Decision Logic

```
IF DATA_INVALID
    STOP

IF MARKET_UNSAFE
    BLOCK_NEW_TRADES

IF VWAP_CHOP
    REDUCE_AGGRESSION

IF CURRENT_BIAS = BULLISH
    MONITOR_BEARISH_FAILURE_CONDITIONS

IF CURRENT_BIAS = BEARISH
    MONITOR_BULLISH_FAILURE_CONDITIONS

IF FLIP_SCORE < MIN_FLIP_SCORE
    HOLD

IF FLIP_SCORE >= MIN_FLIP_SCORE
    VERIFY_STRUCTURE

IF STRUCTURE_CONFIRMED
    VERIFY_LIQUIDITY

IF LIQUIDITY_CONFIRMED
    VERIFY_DISPLACEMENT

IF DISPLACEMENT_CONFIRMED
    VERIFY_EXECUTION

IF EXECUTION_VALID
    CLOSE_INVALIDATED_POSITION
    EXECUTE_NEW_DIRECTION

AFTER ENTRY
    MANAGE_DYNAMICALLY

IF MARKET_INVALIDATES_POSITION
    EXIT

IF OPPOSITE_HIGH_CONVICTION_STATE_DEVELOPS
    EVALUATE_FLIP
```

---

## 25. Never Do This

The engine must never:

- revenge trade
- chase every candle
- flip on every VWAP cross
- increase risk after losses automatically
- move stops farther to avoid losses
- fabricate market data
- fabricate volume
- fabricate news
- assume QQQ research directly proves XAUUSD profitability
- assume tick volume equals centralized exchange volume
- claim HFT profitability without testing
- optimize against a tiny sample
- use future information
- use look-ahead bias
- use unavailable information

---

## 26. Backtesting Requirement

Before live deployment, test:

**Data:** multiple years where available; multiple market regimes; broker-specific XAUUSD data; tick-level data where possible.

**Costs:** spread, commission, slippage, execution delay.

**Robustness:** parameter perturbation, walk-forward testing, out-of-sample testing, Monte Carlo analysis, different sessions, different volatility regimes.

**Stress conditions:** normal, wide spread, high volatility, low liquidity, news, rapid reversal, multiple losses, execution delay, slippage.

**Evaluate on:** expectancy, profit factor, Sharpe, Sortino, maximum drawdown, recovery factor, win rate, average win, average loss, trade frequency, MFE, MAE, flip accuracy, false-flip rate, execution cost.

---

## 27. Source Research Boundary

The VWAP research that inspired this architecture (Zarattini & Aziz, 2023, "VWAP: The Holy Grail for Day Trading Systems" — see `index.html`'s Flipdemon HFT Pro panel note) studied QQQ and TQQQ using 1-minute data. Its reported results must remain labeled as **source research** and must **not** be presented as evidence that this Flipdemon X15 architecture will produce equivalent results on XAUUSD. Any XAUUSD performance claim must come from independent XAUUSD testing.

---

## 28. Primary Output

For every evaluation cycle, produce an internal state object conceptually equivalent to:

```
SYMBOL, TIMEFRAME, SESSION, PRICE
VWAP, VWAP_DISTANCE, VWAP_DISTANCE_ATR, VWAP_SLOPE, VWAP_STATE, VWAP_PERSISTENCE, VWAP_CROSSINGS
MARKET_REGIME
LIQUIDITY_STATE
STRUCTURE_STATE
DISPLACEMENT_STATE
MICROSTRUCTURE_STATE
FLIP_DIRECTION, FLIP_SCORE
EXECUTION_SCORE
RISK_STATE
POSITION_STATE
ACTION
INVALIDATION
```

Possible final actions:

```
NO_TRADE
WATCH_LONG        WATCH_SHORT
LONG              SHORT
HOLD_LONG         HOLD_SHORT
REDUCE_LONG       REDUCE_SHORT
EXIT_LONG         EXIT_SHORT
FLIP_LONG         FLIP_SHORT
EMERGENCY_EXIT
LOCK_SYSTEM
```

---

## 29. Final Operating Principle

The objective is not to predict every market movement. The objective is to detect when the current directional hypothesis has become invalid, and when the opposite hypothesis has accumulated enough independent evidence to justify participation.

- VWAP identifies equilibrium and directional state.
- Liquidity identifies where orders may be concentrated.
- Structure identifies market-state transitions.
- Displacement identifies urgency.
- Microstructure identifies execution conditions.

The Flipdemon engine connects those observations into a controlled state transition.

**Do not trade more. Trade only when the state changes with sufficient evidence.**

The system may operate aggressively, but its aggression must come from speed, selectivity, adaptive execution and controlled risk — not from uncontrolled leverage or indiscriminate trading.

---

## Relationship to the current implementation

The live "Flipdemon HFT Pro" panel in `index.html` today implements a small, honest slice of this spec: session VWAP from tick-count-weighted bars, a long-above/short-below/flip-on-close rule, and three risk dials (leverage, pyramiding, instant flip). It does **not** yet implement:

- the eleven-state state machine in §5 (it only tracks FLAT/WAIT/LONG/SHORT)
- liquidity, structure, displacement, or microstructure detection (§6, §7, §10, §11)
- the weighted flip-confidence score (§8) or anti-chop cooldown engine (§9)
- news/volatility protection (§18), execution safety checks against live MT5 symbol specs (§14, §19), or telemetry (§20)
- direct MT5 EA integration (§23) — it currently only reads bridge ticks and pre-fills the manual order form, it does not call into the EA

Building those out is a substantial follow-on project, not a drop-in change, since most of §6–§22 requires structured OHLCV history and order-flow data the browser-side bridge does not currently provide (it only pushes bid/ask ticks). Treat this document as the target architecture to implement incrementally against, not as a description of what already runs.

See also `docs/qqq-tqqq-regime-engine-spec.md` — a separate gatekeeper/risk-governor layer meant to sit in front of Flipdemon (its §19 describes the intended hierarchy: Flipdemon's flip signal becomes a request the regime engine approves, throttles, or blocks before execution). Neither spec is implemented yet.

Execution Quality (§8) and the slippage check in Execution Safety (§19) are the two places this document names an explicit external standard rather than an internal heuristic: Patnaik & Thomas, *Profitability of Trading Strategies on High-Frequency Data, with Trading Costs* (SSRN 568363, 2004) — a depth-weighted impact-cost model, reconstructed from real limit-order-book snapshots, standing in for "what did this fill actually cost" instead of a quoted-price assumption. Nothing in the current build measures this; it requires order-book depth data the live panel doesn't have access to (MT5 ticks give bid/ask, not depth). Treat both components as `UNAVAILABLE` rather than passing until that data exists.
