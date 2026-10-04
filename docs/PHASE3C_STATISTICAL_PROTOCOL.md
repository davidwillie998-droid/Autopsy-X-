# Phase 3C Statistical Protocol

Frozen before any Phase 3C archive is analyzed (it can be, and is, written
before acquisition even completes, since it reuses the Phase 3B statistical
framework unchanged). Everything in `autopsyx.research.phase3b_stats` and
`autopsyx.research.phase3b_contract` is imported, not reimplemented: the
minimum-sample formula, the six eligible hypotheses (H1, H3, H4, H8, H9,
H10) with their exact feature/target/horizon definitions, the exclusion of
H2/H5/H6/H7, Pearson/Spearman, the block-permutation null, Benjamini-
Hochberg FDR, winsorizing, and the partial-correlation confound check are
all the same code, called the same way.

## What Phase 3C adds (new code, same inputs/outputs shape)

1. **A larger, multi-window archive set.** The Phase 3B pipeline's
   `eligible_archives()` read the inclusion list straight from the frozen
   Phase 3A evidence file. Phase 3C's archive set is Phase 3A's eligible
   archives (A, C, D2 -- B is not replayable) plus every newly acquired
   archive that independently passes the exact same provenance gate
   (`data.provenance.verify()` returns `verified: true`).

2. **The statistical unit, explicit everywhere.** Every reported number
   distinguishes raw joined rows from distinct independent tokens; the
   minimum-sample gate is applied to the token count, exactly as the
   Phase 3B pipeline already does (this was itself a correction made
   during Phase 3B, now simply inherited, not re-derived).

3. **A dedicated H10 replication audit** (Phase 3C instruction 9):
   recompute H10 collapsing each token to one representative observation
   (its first forward-joinable row) in addition to the full per-row
   pooled analysis, so the "all rows vs one row per token" comparison is
   explicit rather than inferred from the token-count gate alone; break
   the correlation down by archive; and rerun the adversarial partial-
   correlation check with archive identity (one-hot per archive, residualized
   the same way as the step-index check) as an additional nuisance variable,
   not only step index.

4. **Per-archive / per-cohort breakdown** for any hypothesis whose pooled
   sample reaches MIN_SAMPLE: Spearman and permutation p-value computed
   separately within each archive, reported next to the pooled number. A
   hypothesis that only holds in one archive is reported as unstable,
   per Phase 3C instruction 11; the acceptance rule in section
   "Classification rule" below enforces this mechanically.

5. **A walk-forward OOS gate**, run only if MIN_SAMPLE is reached: tokens
   ordered by their first assessment's `as_of`, the chronologically later
   half held out, the earlier half used for nothing but directional sign
   confirmation (there is no model to fit; the "fit" step pre-registered
   is "the sign and significance of the in-sample half's correlation").

6. **An adversarial data-quality stress battery** (Phase 3C instruction 12),
   implemented as regression tests, not as part of the evidence pipeline:
   each attack (duplicated tokens, repeated-row inflation, archive pooling,
   survivorship bias, look-ahead, late-arriving records, stale snapshots,
   missing-data-as-zero, creator/liquidity/token-age availability bias,
   archive-identity bias, provider-specific coverage, extreme outliers) is
   constructed as a synthetic input and the frozen pipeline is shown to
   either refuse it (contract violation) or classify the resulting
   hypothesis as something other than SUPPORTED/REPLICATED.

## Classification rule (mechanical, predefined)

For each hypothesis, independently:

* **INSUFFICIENT EVIDENCE** if the pooled distinct-token count is below
  `phase3b_contract.MIN_SAMPLE`. No further step runs; this is the Phase 3B
  rule, unchanged.
* Otherwise, the hypothesis is evaluated against every one of: raw
  permutation significance, BH-FDR-corrected significance, the adversarial
  partial-correlation checks (step index and archive identity), winsorizing,
  the chronological-split OOS sign check, and the per-archive breakdown.
  * **FAILED REPLICATION** if it was nominally significant pooled but fails
    any one of: FDR, either adversarial check, winsorizing, or shows a sign
    that is not shared by at least two of the included archives with their
    own n >= 3.
  * **REPLICATED EVIDENCE** only if it survives every one of the above, the
    OOS sign matches the in-sample sign, and the per-archive signs agree
    wherever an archive's own n >= 3.
  * **PARTIALLY SUPPORTED** is not a terminal Phase 3C state: Phase 3C asks
    specifically whether evidence *replicates*, so anything short of full
    replication is FAILED REPLICATION, not a softer label.

The overall Phase 3C classification is:

* **REPLICATED EVIDENCE** only if at least one hypothesis is REPLICATED
  EVIDENCE and none is FAILED REPLICATION under circumstances that
  contradict it (a mixed family is reported exactly as mixed, hypothesis
  by hypothesis; the overall label names the family's state, it does not
  average it away).
* **FAILED REPLICATION** if at least one hypothesis reached MIN_SAMPLE and
  was tested to a conclusion that did not replicate, and none replicated.
* **INSUFFICIENT EVIDENCE** if no hypothesis reached MIN_SAMPLE at all.

No hypothesis is added, removed, or reworded after this document is
written. No threshold here may be adjusted after a result is seen; a
later session finding this document already committed treats it as
binding, identically to the Phase 3B contract.
