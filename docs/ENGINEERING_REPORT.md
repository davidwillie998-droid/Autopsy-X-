# AUTOPSY X FLIPDEMON EXTREME — Engineering Report

**Applies to commit:** abfa07c
**Phase status:** 12 of 12 for the 44-section autonomous-execution spec
plus the 32-section institutional liquidity/microstructure/alpha upgrade.

This report assembles Sections A-C (each already committed as its own
discrete artifact, listed below) into one place, plus the closing
full-repo verification pass. It does not restate their content in full —
follow the links for the actual trace/derivation. This document is the
index and the verdict, not a duplicate.

- Section A — [`docs/RISK_INVARIANT_AUDIT.md`](./RISK_INVARIANT_AUDIT.md) (commit `805ac80`)
- Section B — [`docs/MODULE_WIRING.md`](./MODULE_WIRING.md) (commit `abfa07c`)
- Section C — [`docs/VERIFICATION_STATUS.md`](./VERIFICATION_STATUS.md) (commit `49fab30`)

---

## Section A summary — Risk Invariant Audit: PASS

`CRiskEngine`'s risk-per-trade clamp (0.05%-2.0% of equity, write-once at
`Configure()`) holds end-to-end through `CAdaptiveFlipEngine`'s sizing
multiplier and every `.mq5` call site. Traced worst-case per path, not
inferred from architecture description: the AFE multiplier is applied to
the lot size (never to the risk percent, never as a divisor), the AFE
scaler is bounded `<=1.0` by four independent mechanisms, and no
reciprocal/`1/x` path exists anywhere `afeRiskMultiplier` is used.

One finding, already fixed (commit `bfd079e`, ahead of the audit
writeup): `CalculateLotSize()`'s broker-volume normalization ran before
the `m_maxExposureLots` exposure clamp, not after, so a non-step-aligned
configured exposure cap could have produced a non-broker-valid return
value. Latent under the default config (`1.0`, which is step-aligned for
virtually every broker), not live — fixed regardless, so the guarantee no
longer depends on the config being well-behaved.

## Section B summary — Module Wiring Map

Of 53 files in `MQL5/Include/AutopsyX/`, **25** (24 engine classes +
`Defs.mqh`) are reachable from the live EA; **28 are not**, confirmed by
checking the full transitive `#include` closure, not just the main
file's direct includes. This covers the entire FLIPDEMON EXTREME Phase
2-6 execution-layer redesign (`StructureEngine`, `CompositeDirection`,
`ExecutionEligibility`, lifecycle/duplicate-guard/restart-recovery/
reconciliation, Monte Carlo, Kelly) and the entire institutional-engine
build from this session (data integrity through Dashboard v3). No
`OnTradeTransaction` handler exists in the file at all.

**The live-trading surface of this EA today is the original FLIPDEMON
EXTREME v1 signal/risk stack** — momentum/microstructure/liquidity/
regime/signal-score/flip/anti-chop, the order-flow suite, AFE, VWAP,
gated by `RiskEngine`/`EmergencyControls`, sized per Section A, logged by
`TradeAutopsy`/`Statistics`, displayed by `Dashboard`. Everything built in
the institutional-engine phases of this session is real, reviewed code
that does not currently affect a single live trading decision.

## Section C summary — Verification Status

**Never compiled** (no MetaEditor in this build environment — every
verification pass has been brace/paren balance-checking plus repeated
code-review, human and AI, never an actual compiler). **Python research
harness: 27 tests passing**, but that verifies the Python statistical
tooling, not the MQL5 bot — no MT5 Strategy Tester run has been
performed, and no demo or live forward test has been run. See the full
page for the itemized "what compilation would catch that review cannot"
list and the known-unknowns (feed dependence, broker dependence, regime
coverage, latency).

---

## Full-repo balance-check (this commit)

Every `.mqh`/`.mq5` file in `MQL5/` — 54 files, all of them, not a
sample — re-checked for brace/paren/bracket balance as the closing step
of this report:

```
$ find MQL5 -name "*.mqh" -o -name "*.mq5" | wc -l
54
$ python3 balance_check.py <all 54 files>
(0 mismatches — every file reports "OK (balanced)")
```

## Python test suite (this commit)

```
$ python3 -m pytest python/tests/ -q
27 passed in 17.59s
```

---

## What "architecturally complete, verification-incomplete" means, concretely

- **Complete**: every section of both source specs (the original 44-section
  autonomous-execution spec and the 32-section institutional
  liquidity/microstructure/alpha upgrade) has a corresponding, reviewed,
  balance-checked module. Every module's header states plainly what is
  paper-sourced (Lee & Ready 1991, Hasbrouck 1991, Malhotra SSRN 3306817,
  Zarattini & Aziz 2023) versus engineering design, and every
  engineering-design threshold/formula is documented as such rather than
  attributed to a source that doesn't specify it.
- **Verification-incomplete**: Section B is the load-bearing fact here —
  most of what was built is not live. Section A proves the one path that
  IS live (risk-per-trade sizing) holds its invariant under trace. Section
  C states, without hedging, that none of this has been proven to
  compile, backtest against real tick data, or trade.
- **The gap between those two statements is the actual next-step list**:
  compile in a real MetaEditor, run the MT5 Strategy Tester against real
  tick data, and — only after both of those — decide whether and how to
  wire any of the 28 dormant modules into the live path, each such wiring
  decision getting its own review pass under this same discipline.

## Findings across this report (consolidated)

| # | Where | Finding | Status |
|---|---|---|---|
| 1 | `RiskEngine.mqh::CalculateLotSize()` | `NormalizeVolume()` ran before the exposure clamp, not after | Fixed, `bfd079e` |
| 2 | `VWAPEngine.mqh` | Two lookahead bugs (rolling + session-anchored VWAP included the forming bar) | Fixed, `71a8a86` |
| 3 | `VWAPEngine.mqh` | `real_volume` weighting activated on a merely-positive sum, not a majority | Fixed, `71a8a86`, hardened `96c6cb9` |
| 4 | `VWAPEngine.mqh::ClassifyVWAPTrend()` | Anti-flip-flop deadband collapsed to 0 when ATR read 0 | Fixed, `71a8a86` |
| 5 | `Dashboard.mqh` / main `.mq5` | "[EXIT ARMED]" tag read the global toggle, not the per-position armed flag | Fixed, `71a8a86` |
| 6 | `VWAPEngine.mqh::GetSessionAnchoredVwap()` | `iBarShift()`'s `-1` error case caught only by numeric accident | Hardened, `96c6cb9` |
| 7 | `VWAPEngine.mqh::ComputeVwapFromRates()` | `count/2` integer division allowed a non-majority `real_volume` threshold on odd window sizes | Hardened, `96c6cb9` |

Every institutional-engine-phase finding from earlier in this session
(ring-buffer eviction bugs, threshold-order guards, the dashboard
zero-initialization trap, missing `ChartRedraw`, and others — see commits
`52b1f56` through `abfa07c`) is documented in its own file's code
comments at the point it was fixed, per this build's established
per-phase discipline, and is not re-listed here since none of that code
is on the live path (Section B).

---

## Sign-off

This report, and every document it indexes, was written from the actual
code as it stands at commit `abfa07c` — not from memory of what was
built or intent about what should exist. Every claim above is either a
command whose output is shown, a file reference that can be opened and
checked, or a specific commit hash. Nothing here should be read as more
than what Section C already says it is: the bot is architecturally
complete and has not been proven to compile, backtest, or trade.
