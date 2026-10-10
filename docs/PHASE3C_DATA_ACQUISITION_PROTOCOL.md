# Phase 3C Data Acquisition Protocol

Frozen before any Phase 3C archive is requested. Written against Phase 3A commit
`617355f` and Phase 3B commit `f21f3bc`. Nothing in this document is set after
looking at a result; the acquisition code itself (`intel/autopsyx/data/acquire.py`,
the Phase 3A observation parsers, `autopsyx seal`/`verify-provenance`) is
imported unchanged from Phase 3A -- Phase 3C does not touch it and does not
fork it. Only the *request parameters* (seed, strata targets, run id) are
new, exactly as every prior archive (A, B, C, D2) already used its own
seed and strata within the same frozen acquisition code.

## Purpose

Determine whether the Phase 3B hypothesis family (H1, H3, H4, H8, H9, H10)
produces a result other than INSUFFICIENT EVIDENCE once the independent-token
sample is larger, using genuinely new, independently acquired archives rather
than replaying or duplicating A, B, C or D2.

## Target number of independent tokens

No fixed target is promised, because acquisition yield (how many distinct
pools/tokens a given strata configuration actually selects) cannot be known
in advance. What is frozen instead: each new archive requests a larger
universe than any prior archive (`strata` summing to at least 20 tokens,
versus 5-12 in A/B/C/D2), and at least two independent acquisition windows
are requested, so that the cumulative token count is reported honestly
against the Phase 3B minimum-sample requirement (`phase3b_contract.MIN_SAMPLE
= 85`), whatever it turns out to be. The threshold itself is not lowered to
fit whatever yield results.

## Minimum token age

None beyond what the frozen `select_universe` stratification already
enforces (no change to that code). Early-life tokens are retained, as in
every prior archive; token age is not a new inclusion filter.

## Observation frequency

Unchanged from Phase 3A: `cycle_s = 60` (price/liquidity poll), replay step
`5*60_000` ms, `HORIZON_STEPS = 3` (15 minutes), all from the frozen
`acquire.Plan` and `phase3b_contract` -- not re-specified per archive.

## Forward horizons

`HORIZON_STEPS = 3`, identical to Phase 3B. Not re-chosen for Phase 3C.

## Required liquidity conditions

None beyond the frozen stratified selection (`young`, `quiet_young`,
`trending`, `established`). No new liquidity floor is introduced.

## Required wallet/creator coverage

None pre-required for inclusion; coverage is measured and reported (data
audit), never used to exclude a token after the fact.

## Required transaction coverage

None pre-required for inclusion, for the same reason.

## Archive separation rules

Each Phase 3C archive gets its own `run_id`, its own acquisition start time,
and its own seed for `select_universe`; archives are requested and acquired
sequentially (the acquisition workflow's own concurrency group already
serializes them), and the next request is pushed only after the previous
archive's commit has landed and its workflow has completed -- never two
requests racing against the same branch HEAD. Two or more acquisition
windows are preferred over one large one so an archive-identity effect can
be distinguished from a real relationship (Phase 3C Step 11).

## Inclusion / exclusion rules

An archive is included in Phase 3C evidence if and only if:
1. its acquisition `run.json` reports `status == "COMPLETE"`, and
2. `data.provenance.verify()` returns `verified: true` against it (runner
   hash = independent rebuild 1 = independent rebuild 2 = committed
   canonical-file hash), and
3. it has a live-poll replay window (`replay_window() is not None`); an
   archive with none (like Phase 3A's archive B) is listed but contributes
   zero assessments, exactly as B does today.

No archive is excluded for producing an inconvenient result. The original,
unhashed Phase 3A archive D remains excluded, unchanged, for the same
provenance reason it always was.

## Missing-data treatment

Identical to the frozen Phase 3B rule: a candidate feature or engine field
that was never observed/available by the predictor's assessment time is
dropped from that row, never imputed as zero, never forward-filled.

## Minimum observations per token

No per-token minimum is imposed for inclusion; a token with only one
forward-joinable step contributes one row (and counts once toward the
distinct-token count), nothing more.

## Minimum number of independent tokens

`phase3b_contract.MIN_SAMPLE` (currently 85, derived from an 80%-power,
alpha=0.05 test for a correlation of at least 0.3 via the Fisher-z
approximation). This number is imported from the frozen Phase 3B contract,
not redefined here, and is not lowered if the acquired archives fall short
of it.

## Train/test or walk-forward separation

If, and only if, the pooled distinct-token count for a hypothesis reaches
MIN_SAMPLE, a chronological walk-forward split is used: observations are
ordered by `as_of`, and the OOS evaluation set is the chronologically later
half of distinct tokens (a token belongs wholly to one side, in or out of
sample -- it is never split across the boundary). Feature construction,
normalization, target definition, and hypothesis selection are all fixed
before the split is drawn and do not use OOS-period information. If
MIN_SAMPLE is not reached, OOS evaluation does not run, and the result is
reported as INSUFFICIENT EVIDENCE with that reason, per Phase 3B's own
kill criterion -- not attempted on an underpowered split.

## Contamination rules

A token cannot appear in both archives: each archive's own universe
selection draws from GeckoTerminal's live pool listings at acquisition
time, which are themselves identity-separated by pool address; genuinely
new acquisition windows at different real-world times will not rediscover
the exact same transient pools as the time-limited, hours-old windows A, B,
C and D2 already captured, which the data audit verifies by checking for
token-address overlap across all included archives and reporting any
found, rather than assuming none exists.

## Provenance requirements

Every new archive is sealed by the unchanged `autopsyx seal` runner step
(introduced for D2) and checked by the unchanged `autopsyx verify-provenance`
command: runner hash, two independent rebuilds, and the committed canonical
files must agree exactly. No new hashing algorithm, no new normalization
path.

## Hash requirements

sha256, via the same two canonical-dataset hashes Phase 3A already defines
(`phase2_records`, `phase3a_observations`), plus the Phase 3B contract hash
(unchanged) and a new Phase 3C statistical-protocol hash (frozen alongside
this document).

## Acquisition log (appended as archives land; not predictions, not edited retroactively)

* **Archive E** (`p3c-sol-20261004e`, 22-token universe, `rpc_max_pages=2`, `rpc_max_txs=30`): completed
  (`run.json["status"] == "COMPLETE"`), provenance verified exactly (runner hash = rebuild 1 = rebuild 2 =
  committed canonical hash). However `cycles == 0`: the Phase 3A-plan enrichment pass for 22 tokens
  (funding/liquidity/news/social collection, run once before the price-polling loop) took longer than
  `duration_s`, so the loop's own elapsed-time check exited before a single price-polling cycle ran. The
  archive therefore has rich observation-layer data (2974 observations across 22 tokens) but no live-poll
  replay window, exactly like Phase 3A's archive B, and contributes zero journal/assessment rows. This is an
  acquisition-*parameter* problem (enrichment cost scales with token count and RPC page/tx budget), not a
  methodology change; the frozen acquisition code is unchanged. Archive F reduces `rpc_max_pages` and
  `rpc_max_txs` and the universe size specifically to keep enrichment well inside the duration budget, decided
  before archive F's own acquisition started and before any archive F result exists.

## Failure conditions

If a requested archive's `run.json` does not report COMPLETE, or its
provenance does not verify exactly, that archive is excluded and reported,
not substituted or silently retried into a different conclusion. If every
newly acquired archive fails provenance, Phase 3C reports FAILED
ACQUISITION for the expansion step and falls back to reporting the
Phase 3B result unchanged (still INSUFFICIENT EVIDENCE at n=22 tokens),
rather than inventing data.
