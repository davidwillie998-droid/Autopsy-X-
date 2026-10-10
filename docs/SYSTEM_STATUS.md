# AUTOPSY X FLIPDEMON EXTREME — System Status

Single source of truth for "how far along is this, really." Every claim
below is one of seven distinct stages, and reaching one says nothing about
the others — they are not a ladder where each implies the ones before it
in the usual sense of "more done." Full evidence for every line is in
`docs/PHASE6_VERIFICATION_REPORT.md`.

**Do not read any single word below ("built," "tested") as "ready."**
Read the specific stage.

---

## The seven stages, defined

- **BUILT** — the code exists, is structurally complete, and has been
  balance-checked (brace/paren matching) and code-reviewed.
- **TESTED** — an executable test suite runs against it and passes, in an
  environment that can actually execute the code (Python, in this repo).
- **REAL-DATA TESTED** — tested against real historical market data, not
  synthetic/simulated data, with a documented methodology.
- **COMPILED** — a real MQL5 compiler (MetaEditor) has built the code and
  reported zero errors.
- **STRATEGY-TESTED** — the MT5 Strategy Tester has run it against
  historical data end-to-end (init → ticks → orders → shutdown).
- **FORWARD-TESTED** — it has run live or on a demo account, in real time,
  watching real (not historical) ticks arrive.
- **LIVE-VALIDATED** — it has traded real money for a meaningful period
  with reviewed, satisfactory results.

## Status by component

| Component | BUILT | TESTED | REAL-DATA TESTED | COMPILED | STRATEGY-TESTED | FORWARD-TESTED | LIVE-VALIDATED |
|---|---|---|---|---|---|---|---|
| Layer 1 (live trading stack, 25 modules) | YES | NO¹ | N/A | NO | NO | NO | NO |
| Layer 2 (institutional upgrade, 28 modules) | YES | NO¹ | N/A | NO | NO | NO | NO |
| Layer 3 (10X Market Intelligence, 6 modules) | YES | YES (Python reference only) | PARTIAL² | NO | NO | NO | NO |
| Layer 4 (ORB / Noise-Area strategies, 2 modules) | YES | NO¹ | N/A | NO | NO | NO | NO |
| Phase 5 research pipeline (`research/information_value/`) | YES | YES (136+9 tests) | YES | N/A (Python, not MQL5) | N/A | N/A | N/A |
| Phase 6 architecture-invariant tests | YES | YES (9 tests) | N/A | N/A (Python, not MQL5) | N/A | N/A | N/A |

¹ No MQL5 code anywhere in this repository has ever been executed. "TESTED"
for the MQL5 layers means only balance-checking and manual/AI code review
— genuinely different from and weaker than an executed test, and never
described as equivalent.

² Real-data testing exists for 2 of Layer 3's 6 modules' underlying
concepts (return-serial metrics from Volatility/Seriality, and
Information Transmission) — see the Phase 5 result below. Regime's real
ATR-gated classification, `CVolatilityEngine`'s state taxonomy, and Shock
DNA were not real-data testable at all (missing OHLC XAUUSD data), and
Market State's own real-data-relevant fields (range/gap/ATR) are in the
same position.

## The two claims most likely to be misread

**"145 tests passing" is a TESTED claim about Python code, not a
COMPILED or STRATEGY-TESTED claim about the MQL5 EA.** The Python test
suite verifies: the Phase 4A/4B statistical reference implementations, the
Phase 5 real-data research pipeline, and (as of Phase 6) 9 static-analysis
checks over the MQL5 source *text*. It has never executed a single line of
MQL5.

**Phase 5's real-data research reaching REAL-DATA TESTED does not mean
Layer 3 reaching KEEP.** The tested result was negative: 0 of 54
hypotheses survived Benjamini-Hochberg correction
(`docs/PHASE5_INFORMATION_VALUE_REPORT.md`). REAL-DATA TESTED describes
the rigor of the test, not its outcome.

## What has never happened, at all, in this repository's history

- No MQL5 compiler has ever run against this code.
- No MT5 Strategy Tester run has ever occurred.
- No forward test (demo or live, watching real-time ticks) has ever run.
- No real money has ever been risked.

These four facts have been true since the project's first commit and
remain true after Phase 6. Phase 6 did not attempt to change them — it
verified the architecture *up to* the point where a compiler becomes the
next possible step, and reported honestly that the step itself has not
been taken.

## Final gate classification (Phase 6)

**ARCHITECTURALLY VERIFIED.**

Not ARCHITECTURALLY VERIFIED *and ready for controlled integration* —
compilation and a Strategy Tester smoke run remain outstanding
prerequisites even for that, per `docs/PHASE6_VERIFICATION_REPORT.md`
§19-20. Not BLOCKED — no defect was found that prevents safe progression;
Phase 6's own adversarial hard-stop audit came back clean. Not VERIFICATION
INCOMPLETE in the architectural sense — the ownership map, execution
path, and all ten risk invariants were each traced to a real, cited
implementation path, not assumed. The material verification that remains
outstanding is downstream of the architecture (compile, test, forward-run)
and is named explicitly as the blocker, not hidden inside a more
comfortable-sounding label.
