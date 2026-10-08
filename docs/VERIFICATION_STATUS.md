# Verification Status

**Last updated:** 2026-09-25
**Applies to commit:** 71a8a86cf1bb3664a28a97f657bf8243c0b6dd52

This page states plainly what has and has not been verified about
AUTOPSY X FLIPDEMON EXTREME. It is the first page of the
engineering report for a reason.

---

## Compilation

**Status: NEVER COMPILED.**

No MetaEditor has been available in the build environment.
Verification has relied on:

- Manual brace / paren / bracket balance-checking
- Repeated code-review passes (human + AI)
- Manual header/`#include` consistency checks

**What compilation would catch that review cannot:**

- Type mismatches across module boundaries
- Scope and lifetime bugs (shadowing, uninitialized structs)
- Silent overload resolution differences
- Enum ordinal mismatches
- Const-correctness violations on `const` structs (e.g. `SAxTradeThesis`)
- Unused-variable and unreachable-code warnings
- Any error introduced by a header rename or a moved function

**Conclusion:** the codebase has been reviewed carefully, but it has
not been proven to *compile*, let alone run.

---

## Backtesting

**Python harness:** `backtest.py`, `stress_test.py`, `alpha_decay.py`,
`correlation.py` — **27 tests passing.**

**Critical caveat:** if these modules re-implement strategy logic in
Python rather than calling into the MQL5 runtime, then they test a
*Python model of the bot*, not the bot. The two can drift.

**MT5 Strategy Tester:** **NOT RUN.** No tick-data backtest of the
actual MQL5 Expert Advisor has been performed.

---

## Forward Testing

- Demo/paper trading on live feed: **NOT RUN**
- Small-capital live run: **NOT RUN**

---

## Known Unknowns

- **Feed dependence:** tick vs `real_volume` behavior is documented
  and defended against, but not observed across multiple brokers.
- **Broker dependence:** filling mode, stops level, freeze level are
  detected at runtime, not verified across broker population.
- **Regime coverage:** which of the nine regime classes has the bot
  actually been exposed to? Unknown without live/backtest data.
- **Latency:** execution-quality measurement exists in code; real
  latency distribution unknown.

---

## What This Means

The bot is architecturally complete through Phase 11 and has an
extensive internal safety design. It has NOT been proven to compile,
backtest, or trade. Any statement to the contrary should be treated
as marketing, not engineering.
