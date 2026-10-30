# AUTOPSY X — Consolidated System Status

This file preserves the two independently maintained project status records that were created at the same path on divergent branches. The Solana intelligence engine and FlipDemon Extreme HFT are separate workstreams. Their readiness claims, evidence, tests, and execution permissions must not be conflated.

---

## AUTOPSY X intelligence and Solana research status (target-branch snapshot)

Living status of the AUTOPSY X intelligence system, generated from `artifacts/phase3a/PHASE3A_EVIDENCE.json`. The frozen Phase 2 status is in `docs/PHASE2_SYSTEM_STATUS.md`.

## Current phase: 3A (data-coverage hardening)

* Commit: `4a56fc46b6f68ad42f1e460168704ff8a8a3a02c`
* Branch: `ccr-dea9382c-vwhvi6`
* Working tree: clean for intel/autopsyx, intel/config, intel/migrations
* Tests: Passed 265, Failed 0, Skipped 0
* Provider error rate: 6.5% (93 of 1421 requests)
* Freshness compliance: 0.8% (663 governed evaluations, 658 stale)
* Funding coverage: 4 of 30 archive-token rows OBSERVED (13.3%)
* Liquidity coverage: 30 of 30 archive-token rows OBSERVED (100.0%); chain-derived add/remove in 4 rows (13.3%), the rest is provider pool-creation metadata only
* Creator-state coverage: 25 of 30 archive-token rows OBSERVED (83.3%)
* Holder-state coverage: 20 of 30 archive-token rows OBSERVED (66.7%)
* News coverage: 0 of 30 archive-token rows OBSERVED (0.0%)
* Social coverage: 0 of 30 archive-token rows OBSERVED (0.0%)
* Multi-day collection: NOT PERFORMED (longest span on one universe 0.044715 days)
* Universe size: 30 distinct tokens over 4 archives
* Replay determinism: VERIFIED
* Look-ahead: NONE DETECTED
* Traceability: VERIFIED
* Evidence integrity: VERIFIED
* Finalization gate: PASS
* Readiness: NOT_READY

## Readiness reasons

* thresholds not approved by a human (config/phase3a_readiness.toml: approved = false)
* threshold funding_transfer_min_share is UNSET (metric funding_transfer_share = 0.133333)
* threshold liquidity_vault_delta_min_share is UNSET (metric liquidity_vault_delta_share = 0.133333)
* threshold creator_state_min_share is UNSET (metric creator_state_share = 0.833333)
* threshold holder_state_min_share is UNSET (metric holder_state_share = 0.666667)
* threshold news_min_share is UNSET (metric news_share = 0.0)
* threshold social_min_share is UNSET (metric social_share = 0.0)
* threshold freshness_min_compliance is UNSET (metric freshness_compliance = 0.007541)
* threshold provider_max_error_rate is UNSET (metric provider_error_rate = 0.065447)
* threshold multi_day_min_days is UNSET (metric multi_day_days = 0.044715)
* threshold universe_min_tokens is UNSET (metric universe_tokens = 30)

## What runs

* Acquisition (read-only, keyless): GeckoTerminal, DexScreener, public Solana RPC, GDELT, Reddit.
* Observation contract with explicit availability states; Phase 2 records unchanged.
* Deterministic point-in-time replay; PostgreSQL schema through the latest migration.
* No order placement, no wallets, no strategy logic, no hypothesis testing.

## Limitations

* Multi-day collection was not performed: GitHub-hosted jobs stop after hours and scheduled workflows run only on the default branch. The collector is ready for it (frozen universe, chained runs that refuse an edited universe).
* Funding transfers, chain-derived liquidity events, news and social exist only where an archive was acquired with the Phase 3A plan; the Phase 2 archives report them UNAVAILABLE.
* Liquidity add/remove detection sees only venues whose vault token accounts are owned by the pool address; other venues are reported as a coverage gap, never as no liquidity change.
* GDELT gives crawler time, not publication time; news publication time is NOT_OBSERVED by construction.
* Whether a news item or post truly concerns its token is not verified (reference_verified_state UNKNOWN).
* X and Telegram are UNAVAILABLE: no credentials are held and none were substituted.
* Funding beneficiaries are never inferred; every transfer carries beneficiary_status UNKNOWN.
* Freshness has one approved threshold (max_price_age_ms), applied to the per-cycle market endpoints only.
* Readiness thresholds do not exist yet; the gate stays NOT_READY until a human approves values.
* TimescaleDB is unavailable here; hypertable calls are stubbed on PostgreSQL 16 as in Phase 2.


---

## FlipDemon Extreme HFT status (source-branch snapshot)

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


## Integration note

The Solana intelligence status above describes a read-only, keyless research system and its Phase 3A evidence snapshot. The FlipDemon status below describes the MT5 EA and its separate verification stages. Neither status record supersedes the other. Update each section only from its own current evidence and preserve the separation of execution authority.
