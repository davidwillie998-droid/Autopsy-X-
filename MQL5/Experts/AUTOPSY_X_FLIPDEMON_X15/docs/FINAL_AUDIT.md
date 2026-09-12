# FINAL AUDIT (spec Section 51)

Honest answers. Where the honest answer is "this hasn't been proven yet,"
that is stated directly rather than papered over — per the spec's own
Section 47, success here is defined as controlled risk and a measurable
process, not a claim of guaranteed profit.

## EDGE — where exactly does the edge come from?

There is no proprietary indicator claimed to produce edge. The entry logic
is a fairly standard smart-money-concept read (swing structure, BOS/CHOCH,
displacement, order blocks, FVGs, liquidity pools) gated by regime
alignment and a minimum reward:risk. **This is a hypothesis, not a proven
edge.** `ProbabilityEngine` and `ExpectedValue` exist specifically to test
that hypothesis against the EA's own live trade journal, and
`ExpectedValue::Compute` returns a net-zero/negative result (which blocks
trading) whenever `Probability.confidence` is low because the sample is
still small. Until dozens of real closed trades accumulate per setup
class, the EV gate is intentionally conservative rather than assuming the
structural logic is profitable.

## RISK — what happens during 10 consecutive losses?

At loss #2 (`Inp_LossStreak_Reduce1`) risk is cut by
`Inp_LossStreak_CutFactor` (default 50%). At loss #3
(`Inp_LossStreak_Reduce2`) it is cut again (25% of base). At loss #5
(`Inp_LossStreak_Halt`) new trades stop entirely
(`DrawdownEngine::LossStreakForcesHalt`) until a human reviews the
account — trading does not silently resume. This is all in
`DrawdownEngine.mqh` / `RiskEngine::ComputeFinalRiskPct` and never
increases size on a loss.

## COMPOUNDING — how does exposure change as equity grows?

Position size is always `equity × risk% ÷ stop-distance-in-money`
(`RiskEngine::ComputeLots`), so lot size compounds automatically with real
equity — there is no separate "compounding schedule" to drift from
reality. `CompoundingEngine` tracks the resulting equity curve
(high-water mark, drawdown-from-high, R-multiples) purely for reporting
and for the drawdown/win-streak governors; it does not project or assume
future compounding.

## RUIN — what conditions can destroy the account?

Modeled explicitly: a negative-expectancy regime that persists long enough
to defeat both the loss-streak cuts and the ruin-probability governor
before `DriftEngine`/`RuinEngine` catch it; a broker/data outage that
prevents `PositionManager` from managing an open stop; or a gap
(weekend/news) larger than the placed stop, which no position-sizing model
can fully prevent — `Inp_MaxSpreadPoints` and the news blackout reduce but
do not eliminate this. `RuinEngine` estimates probabilities of 10/20/30/
50/75%/near-total drawdown from the EA's *own* realized win rate and
payoff ratios (not an assumed edge), and both its analytical and Monte
Carlo readings are always labeled `MODEL ESTIMATE`.

## REGIME — what happens when the market changes?

`RegimeEngine` reclassifies every symbol every cycle from fresh ADX/DI/
Bollinger-width data (no cached "was trending" state carried over).
`REGIME_CHAOS`, `REGIME_REVERSAL`, `REGIME_CONTRACTION`, and
`REGIME_UNKNOWN` all force `RegimeEngine::ForcesCapitalPreservation() ==
true`, which is checked before any other analysis is even attempted for
that symbol that cycle (rung 4 of `EvaluateSymbol`).

## EXECUTION — what happens when spreads explode?

`BrokerAdapter::PreTradeCheck` rejects the symbol before *and* after stop
distance is known if the spread exceeds `Inp_MaxSpreadPoints`. Separately,
`ExecutionEngine`'s rolling execution score falls with realized slippage
and rejected orders; once it drops below `Inp_ExecutionScoreFloor`, new
entries are throttled (rung 15) regardless of spread at that instant —
i.e. a broker that is *generally* misbehaving gets throttled even between
individual spread spikes.

## VOLATILITY — what happens during abnormal movement?

`VolatilityEngine` classifies VERY LOW…EXTREME from a z-score of ATR
against its own trailing distribution (symbol-relative, not a fixed pip
threshold), and separately flags EXTREME/HIGH volatility as
`VOLCHAR_DIRECTIONAL` or `VOLCHAR_CHAOTIC` from recent candle-direction
persistence. `VOLCHAR_CHAOTIC` at `VOL_EXTREME` forces `REGIME_CHAOS`
directly in `RegimeEngine::Compute`, which halts new entries for that
symbol via the regime gate above.

## CORRELATION — what happens when multiple positions become one macro bet?

`CorrelationEngine::EffectivePortfolioRisk` computes a
portfolio-variance-style aggregate (`sqrt(Σ risk_i·risk_j·corr_ij·sign_i
·sign_j)`) over all open EA positions plus the candidate trade, using
measured rolling return correlation (not a hard-coded currency-pair
table). `ExposureEngine` rejects a new trade if this exceeds
`Inp_MaxPortfolioRiskPct`, so five correlated USD trades cannot each pass
the single-trade risk check independently and quietly become one oversized
bet.

## RECOVERY — what happens after MT5 restarts?

`OnInit` calls `ReconstructOpenMetaFromPositions()`, which rebuilds
in-memory metadata for every open EA position (matched by magic number)
directly from the live position's entry/SL/TP/volume — it does not require
the pre-restart in-memory state. `CompoundingEngine` and `DrawdownEngine`
restore their equity high-water mark, win/loss streaks, and any latched
account-halt from `GlobalVariable`s, which survive a terminal restart (they
do not survive `GlobalVariablesDeleteAll` or a different terminal/profile).

## DATA — what happens when external intelligence is unavailable?

DXY/macro correlation (`BiasEngine::MacroAlignment`) and the news calendar
(`IsNewsBlackout`) both return "not checked" rather than a fabricated
reading when the source symbol/calendar isn't available — the caller
either skips that check (news) or does not apply a macro veto it can't
support (bias). No COT, yields, or other unavailable-in-MT5 data source is
referenced anywhere in this codebase; the spec's prohibition on fabricated
intelligence is enforced by simply never claiming those sources exist.

## LOGIC — can any component create an infinite trading loop?

New entries are gated one-per-symbol-per-cycle by the `already_in` check
in `OnTimer` (a symbol with an open EA position is skipped for fresh
entries), and the timer cadence (`Inp_TimerSeconds`) bounds how often the
whole cycle can even run. Pyramiding is separately bounded by
`Inp_MaxAddsPerPosition` and by requiring the position to already be
profitable, so it cannot cycle open→lose→reopen on the same bar.

## ROBUSTNESS — does the strategy survive parameter perturbation?

**Not yet demonstrated.** This codebase has not been backtested, so no
walk-forward or parameter-sensitivity analysis has been run. This is the
single biggest gap between "builds correctly" and "production ready," and
it is Section 39/Section 51's most important warning: do not treat
compilation success, or even a clean demo run, as evidence of a real edge.
Before real capital, run this in Strategy Tester across a multi-year,
multi-regime period, vary each `Risk`/`Opportunity` threshold by ±20%, and
confirm expectancy doesn't collapse — if it does, per Section 39, the
system is fragile and should not go live as configured.

---

## What was and wasn't possible to verify in this environment

This EA was written in a Linux container with no MetaEditor/MQL5 compiler
and no MT5 terminal available, so the "write → compile → read errors →
fix" loop mandated by Section 50 could not be executed here. Every file
was instead written with close manual attention to MQL5 syntax, correct
struct/class field names across files, and matching function signatures at
every call site — a second pass specifically re-checked all cross-file
calls, and fixed one real bug found this way (uninitialized locals feeding
the dashboard when a symbol was rejected early) and two risky-but-uncertain
constructs (struct-valued `?:` ternaries, replaced with plain `if/else`
since MQL5's support for non-scalar ternary operands is not something this
review could confirm without a compiler).

**Compiling this in MetaEditor and fixing whatever the compiler reports is
the required next step before anything else in this audit means much.**
