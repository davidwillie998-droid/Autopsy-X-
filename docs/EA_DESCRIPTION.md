# AUTOPSY X FLIPDEMON EXTREME — Full Description

**Applies to commit:** a6f4aad
**Platform:** MetaTrader 5 (MQL5 Expert Advisor)
**Instruments:** designed for XAUUSD and major FX pairs (24-hour markets,
no single session open)
**Size:** 1,499-line main `.mq5` file, 53 supporting `.mqh` modules, 134
configurable `input` parameters, plus a standalone Python research
package

This document describes the EA as it actually is today, not as it is
eventually intended to become. Two things are true simultaneously and
neither cancels the other out: the codebase is large, carefully built,
and reviewed to a high standard; and most of it does not currently
affect a single live trading decision. Both facts are load-bearing to
understanding what this is.

---

## 1. What this is, in one paragraph

AUTOPSY X FLIPDEMON EXTREME is a fully automated MetaTrader 5 trading
bot built around a core philosophy: **a signal must never automatically
imply permission to trade.** It separates "does a technical setup exist"
from "are current market conditions actually suitable for deploying
risk" into two architecturally distinct layers, with the second layer
able to override the first — refusing, shrinking, or delaying a trade
even when the signal itself looks good. On top of that, it maintains an
enormous, self-documenting paper trail: every closed trade is logged
with dozens of fields describing exactly why it was taken and what
conditions surrounded it, every engineering decision is labeled as
either sourced from a specific academic paper or an explicit,
undisguised design choice, and every phase of construction was
balance-checked and code-reviewed before being called done.

## 2. Two layers, one of which is live

The codebase was built in two large passes over one long development
session, and they are **not equally connected to live trading**:

### Layer 1 — FLIPDEMON EXTREME v1 (LIVE)

The original build. This is what actually trades today. 24 engine
instances, all instantiated in `OnInit()` and called from `OnTick()`/
`OnTimer()`, covering signal generation, entry/exit, risk management,
and reporting. Described in full in Section 3 below.

### Layer 2 — the institutional engine upgrade (NOT LIVE)

A later, much larger addition — 28 additional modules implementing a
liquidity-adjusted alpha, market-microstructure, and drawdown framework
inspired by real market-microstructure literature. Every one of these
modules is written, balance-checked, and code-reviewed to the same
standard as Layer 1. **None of them are `#include`d by the live EA file
— confirmed mechanically, not assumed** (see
`docs/MODULE_WIRING.md`). They exist on disk as reviewed, dormant code.
Described in Section 4 below.

If you only read one sentence of this document: **the bot that runs
today is Layer 1 alone.**

---

## 3. Layer 1 — the live trading stack

### 3.1 Market data and signal generation

- **`CMarketData`** — broker-adapted symbol properties (point, tick
  size/value, volume min/max/step, stops/freeze level) plus a 512-tick
  rolling ring buffer. Every other engine reads through this rather than
  calling `SymbolInfoDouble` directly, so a broker quirk only needs
  handling in one place.
- **`CMomentumEngine`**, **`CMicrostructureEngine`**, **`CLiquidityEngine`**,
  **`CRegimeEngine`** (instantiated twice — once for the trading
  timeframe, once for a higher timeframe used as a confluence filter) —
  the core technical-read layer: momentum, spread/quote-behavior
  microstructure, liquidity conditions, and a 9-way regime classification
  (trend/strong-trend/breakout/range/mean-reversion/high-vol/low-vol/
  chaotic/unsafe).
- **`CSignalScorer`** — combines the above into a 0-100 buy score and
  sell score plus a confidence read, the central number the rest of the
  pipeline acts on.
- **`CFlipEngine`** / **`CAntiChopEngine`** — decide when to reverse an
  open position outright ("flip") versus when repeated back-and-forth
  reversal signals should be suppressed by a cooldown, so the bot
  doesn't whipsaw itself to death in a choppy market.

### 3.2 Order-flow suite

Five engines reading the same tick stream from different angles:
**`COrderFlowEngine`** (buy/sell imbalance from inferred tick direction),
**`CVolumeProfileEngine`** (value-area high/low positioning),
**`CFootprintEngine`** (per-bar stacked-imbalance detection),
**`CPulseEngine`** (a blended 0-100 momentum/flow composite), and
**`CHeatmapEngine`** (a DOM-liquidity approximation, also used to cap
position size against estimated order-book depth when enabled).

### 3.3 Entry, execution, and exit

- **`CEntryEngine`** / **`CExecutionEngine`** — builds and sends real
  orders via `CTrade`, with dynamic spread-aware slippage tolerance.
- **`CSniperEngine`** — an optional precision-entry layer that waits for
  a pullback confirmation before committing, rather than entering the
  instant a signal crosses threshold.
- **`CExitEngine`** — momentum-collapse exits, microstructure-reversal
  exits, max-hold-time (profit/trend-aware, not a fixed timer), spread-
  abnormal exits, execution-quality circuit-breaker exits, breakeven and
  trailing stops, and an optional mechanical VWAP exit (see 3.5).
- **`CVWAPEngine`** — Zarattini & Aziz (2023)-inspired: a bar closing on
  one side of VWAP tends to keep drifting that way. Adapted for 24-hour
  markets (rolling or FX-session-anchored VWAP, not the original paper's
  single NYSE-open anchor) and paired, deliberately, with an
  unconditional mechanical exit the instant a bar closes wrong-side —
  the paper's own finding is that the exit rule is what bounds losses,
  not the entry signal alone.

### 3.4 Risk management — the part with the hardest guarantees

- **`CRiskEngine`** — the account's single source of truth for
  risk-per-trade, **hard-clamped to 0.05%-2.0% of equity at
  configuration time**, never touched again outside that one write. Also
  owns every hard circuit breaker: daily/weekly loss limits (Monday-
  anchored week, not a rolling 7 days), consecutive-loss lockout,
  consecutive-execution-failure lockout, max open positions/exposure/
  directional exposure, max flips per day, max trades in a rolling
  window, margin-usage and margin-level floors, and spread ceilings.
  This invariant — that nothing downstream can ever push risk-per-trade
  above what `CRiskEngine` configured — was formally traced end-to-end
  in `docs/RISK_INVARIANT_AUDIT.md` and holds.
- **`CAdaptiveFlipEngine`** — sits on top of `CRiskEngine`, tracking
  continuous peak-equity drawdown (catches a slow multi-day bleed that
  no single day's loss limit would trip), estimating win probability,
  expected value in R-multiples (net of real spread/commission/swap/
  slippage cost, and an optional square-root price-impact term gated off
  by default since this EA's retail-scale sizing is a price-taker, not a
  price-mover), and an approximate risk-of-ruin figure. It can only ever
  **scale a trade's size down** from what `CRiskEngine` already decided
  — never up — enforced by four independent bounding mechanisms in code,
  not just by convention.
- **`CEmergencyControls`** — execution-mode switch and a manual kill
  state, plus the on-chart KILL ENGINE button.

### 3.5 Logging, statistics, and display

- **`CTradeAutopsy`** — every closed trade (including partial scale-outs)
  written to a CSV with 43 columns: entry/exit reasoning, scores,
  regime, MFE/MAE, gross/net P&L, AFE readings at entry, VWAP state, and
  more.
- **`CStatistics`** / **`CAccuracyEngine`** — win rate, profit factor
  (both gross and net-of-cost), expectancy, max drawdown, entry accuracy,
  exit efficiency, and a 5-state profitability gate
  (`INSUFFICIENT_DATA`/`FAIL`/`WEAK`/`PROMISING`/`VALIDATED`) that
  explicitly refuses to call a strategy "validated" off too small a
  sample.
- **`CDashboard`** — the on-chart panel, redrawn on a timer (never every
  tick), showing account/market/position/AFE/order-flow/VWAP state plus
  the kill button.

### 3.6 What this stack will and won't do

It will: trade momentum/microstructure/liquidity/regime-based long and
short signals on one symbol, size every trade off a hard-clamped risk
percent, refuse to trade under a long list of hard circuit-breaker
conditions, flip or exit based on the same signal engines, and log
everything.

It will not, today: read the macro/cross-asset regime, classify market
structure (BOS/CHoCH/MSS), run a 15-gate final-decision matrix, detect
building-but-not-yet-realized ("hidden") risk, or activate a Crisis/
Black-Swan mode — because none of the engines that do those things are
wired in. That's Layer 2.

---

## 4. Layer 2 — the institutional engine upgrade (dormant)

Built to a spec explicitly modeled on institutional-liquidity-adjusted
alpha research, primarily:

> Malhotra, Y., "Guidance to a Goldman Sachs alumnus Hedge Fund with
> $400B-$500B AUM: Alpha Trading Strategies Analysis, Maximizing Alpha
> for Hedge Funds, and High Frequency Econometrics for Analyzing Price
> Impact of Trades, Liquidity, and Market Microstructure," SSRN 3306817
> (2018)

plus Lee & Ready (1991) for trade-direction classification and
Hasbrouck (1991) for the VAR/impulse-response methodology used in the
**separate Python research package** (see Section 5). Every engine's own
file header states explicitly which parts are paper-sourced and which
are this codebase's own engineering design — nothing is attributed to a
paper that doesn't actually specify it.

The intended pipeline, if wired, reframes the whole decision chain from
MARKET→SIGNAL→ENTRY into:

```
MARKET STATE → REGIME → LIQUIDITY → VOLATILITY → MICROSTRUCTURE →
PRICE IMPACT → ALPHA QUALITY → EXECUTION QUALITY → PORTFOLIO RISK →
DYNAMIC DRAWDOWN STATE → TRADE DECISION
```

so the system can say "the setup exists, but conditions are unsuitable
for deploying risk right now" even when a technical signal is valid.

### 4.1 Data quality and regime layers

`CDataIntegrityEngine` (fail-closed "NO TRADE" gate on impossible
prices, stale quotes, a stuck feed, or an abnormal spread — both an
absolute ceiling and a rolling z-score check), `CMacroRegimeEngine`
(reads a real, broker-selectable cross-asset symbol only — never
fabricates a reading it can't get), `CVolatilityEngine` (percentile-rank
volatility classification), `CLiquidityScoreEngine` (blended spread/
tick-activity/velocity/execution-quality/quote-stability score).

### 4.2 Microstructure and price impact

`CTickDirectionEngine` (Lee & Ready 1991 tick-and-quote test, ported
from the Python research module),
`CPriceImpactEngine` (post-execution price-drift tracking across
configurable time horizons), `CInformationContentEngine` (a thin
"signal pressure" relabeling of the live order-flow imbalance — never
claims to be real order-book data, since no retail feed provides that).

### 4.3 Alpha and structure

`CAlphaEngine` (a weighted composite score across macro/regime/
liquidity/volatility/microstructure alignment, minus penalties for
execution cost, price impact, crowding, event risk, and correlation
risk), `CStructureEngine` (BOS/CHoCH/MSS market-structure
classification, explicitly signal-only — verified by inspection to
contain no order-execution call anywhere), `CCompositeDirectionEngine`
(a weighted multi-engine directional vote, also signal-only).

### 4.4 Drawdown, crisis, and capacity

`CDynamicDrawdownEngine` (a 5-state drawdown severity ladder combining
magnitude, velocity, volatility regime, liquidity, execution quality,
and consecutive losses — plus Liquidity-Adjusted Drawdown, LADD, which
scales realized drawdown by current liquidity conditions),
`CHiddenRiskDetector` (building-but-not-yet-realized risk: rising
spread, deteriorating execution, falling tick activity, abnormal
velocity), `CCrisisEngine` (a 4-level Crisis/Black-Swan severity ladder),
`CCapacityCrowdingEngine` (local, self-referential proxies for how much
size the market can absorb and whether this EA is chasing its own
already-extended move — explicitly not real cross-fund positioning
data, which no available feed provides).

### 4.5 The final decision layer

`CTradePermissionMatrix` — the capstone. 15 named gates (8 "hard" gates
that force NO_TRADE or HALT on a single failure, 7 "soft" gates whose
failure count scales the decision down through
TRADE→REDUCE_RISK→WAIT→NO_TRADE rather than a blunt binary) combining
every engine above into one `ENUM_AX_FINAL_DECISION`.
`CDynamicPositionSizing` — a size-down-only multiplier stack combining
the decision, drawdown state, crisis level, alpha quality, and capacity,
architecturally incapable of exceeding the base risk percent (each
component multiplier is pre-clamped to `[0,1]`, and Kelly is
deliberately excluded from this stack per its own report-only
constraint — see 4.6).

### 4.6 Diagnostics, never authorization

`CKellyRuinEngine` — computes the classical Kelly fraction and compares
current risk-per-trade against it, explicitly labeled in its own file
header: "NEVER let this class's output authorize or size a live trade
— this is diagnostics, nothing more." A Monte Carlo projection module
serves the same report-only role.

### 4.7 Attribution, explainability, and Dashboard v3

`CPerformanceAttribution` (P&L broken down by regime/direction/flip-
origin), `CDrawdownAnalytics` (historical drawdown-episode detection
over the closed-trade ledger — distinct from the live drawdown engine,
which only tracks the current one), `CExplainabilityEngine` +
`CExplainabilityLog` (a machine-readable JSON explanation per decision,
logged to its own JSONL file, separate from the trade-outcome CSV since
the two have different granularity), `CInstitutionalDashboard` (a
second, independent on-chart panel — ALPHA/LIQUIDITY/VOLATILITY/
MICROSTRUCTURE/RISK/EXECUTION/FINAL DECISION — deliberately kept as its
own file/class/object-prefix so it never touches the original
dashboard's fragile hand-audited pixel layout).

### 4.8 Operational-layer remnants

Also dormant: `CExecutionEligibility` (thesis-quality gate),
`CDuplicateGuard`, `RestartRecovery`, `CTradeReconciler` (needs an
`OnTradeTransaction` handler that doesn't exist in the file at all —
confirmed), and a `TradeLifecycle` state machine more granular than the
simple position struct the live code uses today.

---

## 5. The Python research package (separate from the MQL5 bot entirely)

`python/autopsy_research/` — never imported by, called from, or a
dependency of anything in `MQL5/`. Genuinely installable and testable in
this environment (unlike the MQL5 side, which has never seen a
compiler): **27 tests, currently all passing.**

- `trade_direction.py`, `spreads.py` — Lee & Ready (1991) tick/quote
  trade-direction classification, spread/order-flow construction.
- `var_model.py`, `diagnostics.py` — a Hasbrouck (1991)-style 2-equation
  VAR of net order flow and quote changes with orthogonalized
  impulse-response analysis, plus stationarity/residual/stability
  diagnostics. One test here (`test_var_model_recovers_known_coefficient`)
  caught a real Cholesky-ordering bug during development — the lag-0
  impulse response was silently zero until the column order was fixed.
- `backtest.py`, `stress_test.py` — in/out-of-sample splits, walk-forward
  windows, block-bootstrap Monte Carlo resampling, parameter-
  perturbation grids, and an adversarial stress-test suite (shock
  injection, cost-multiplier stress, win-rate-degradation stress).
- `alpha_decay.py`, `correlation.py` — a two-window Sharpe-decay
  detector (its own docstring documents a real, empirically-measured
  statistical caveat about sampling noise at small window sizes, caught
  by a test that itself needed correcting during development) and a
  strategy-correlation/crowding proxy across caller-supplied return
  streams.

This package is meant for a human researcher to run offline against real
trade/quote data and, if they choose, export fitted parameters as static
config a live engine could later read — that consumption path does not
exist yet.

---

## 6. Safety principles that hold across the entire codebase, live or dormant

- **No martingale, no averaging down, no unlimited risk, ever** — the
  one rule repeated in nearly every risk-adjacent file's header, and
  traced formally for the live path in `docs/RISK_INVARIANT_AUDIT.md`.
- **Fail closed, not open** — every gate defaults to blocking when data
  is unavailable, stale, or ambiguous, never to a permissive default.
- **Never fabricate a reading** — insufficient data returns a neutral
  value or an explicit "unavailable" state, never a guessed number
  dressed up as real. This shows up dozens of times across the codebase
  as an explicit, commented design choice.
- **Paper-sourced vs. engineering design, always labeled** — every
  formula, threshold, and weight either cites the specific paper finding
  it implements, or is explicitly marked as this codebase's own choice.
  Nothing is attributed to a source that doesn't actually specify it.
- **Every feature ships opt-in, off by default** — `InpUseVWAPExit`,
  `InpUseAdaptiveFlipEngine`, `InpUseImpactCostSizing`, `InpUseHeatmap`,
  and (per `docs/WIRING_PLAN.md`) every one of the 28 dormant modules'
  eventual toggle, all default `false`.
- **Signal generation and risk/execution permission are architecturally
  separate** — no signal-producing class anywhere in this codebase
  contains a `CTrade`/order-execution call. Verified by inspection, not
  assumed, for every engine this property was claimed of.

---

## 7. Verification status — read this before trusting anything above

**Never compiled.** No MetaEditor has been available in the build
environment at any point. Every verification pass on the MQL5 side has
been manual brace/paren/bracket balance-checking plus repeated
code-review (human and AI) — never an actual compiler. See
`docs/VERIFICATION_STATUS.md` for the itemized list of what a real
compile would catch that this process cannot (type mismatches, scope/
lifetime bugs, enum ordinal mismatches, const-correctness violations,
and more).

**No MT5 Strategy Tester run. No demo or live forward test.** The
Python test suite (27 passing) verifies the Python statistical tooling
only — it has no bearing on whether the MQL5 bot itself runs correctly.

**The honest headline, unchanged since it was first written:** the bot
is architecturally complete and verification-incomplete.

---

## 8. Where to go next

- `docs/MODULE_WIRING.md` — the mechanically-derived list of exactly
  which 25 files are live and which 28 are not, and why.
- `docs/WIRING_PLAN.md` — a 5-tier order for wiring the 28 dormant
  modules in eventually (risk-reducers first, signal-generators last,
  each with its own dependency chain, off-switch, and acceptance test),
  plus one concrete accessor-exposure gap discovered while writing it.
- `docs/RISK_INVARIANT_AUDIT.md` — the formal trace proving the live
  risk-per-trade invariant holds end-to-end.
- `docs/ENGINEERING_REPORT.md` — the Phase 12 closing report indexing
  all of the above plus a consolidated findings table.
- `python/README.md` — the research package's own documentation.
