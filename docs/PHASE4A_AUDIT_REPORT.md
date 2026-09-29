# Phase 4A Independent Statistical Audit

**Scope:** commit `8557cb9` (Phase 4A implementation), report hash
`443b694`. Adversarial audit of `InformationTransmissionEngine.mqh` and
`python/autopsy_research/lead_lag.py`. Not a re-run of prior review —
every claim below was traced against the actual code and, where
possible, verified by running an adversarial experiment and reporting
its real output.

---

## 1. Mathematical specification

Traced from the actual implementation (`lead_lag.py`, the tested
reference; `InformationTransmissionEngine.mqh` mirrors it), not
inferred from comments.

**Lagged association.** For lag ∈ [0, maxLag], with `n` = number of
paired observations available:
```
corr(lag) = PearsonCorr(leader[0 : n-lag], receiver[lag : n])
```
Pearson correlation, sample formula, clipped to [-1, 1]. Returns exactly
`0.0` (not NaN) when either side has zero variance or fewer than 2
points.

**Best lag.** Among lags with `sample_count(lag) ≥ min_sample_size`,
`best_lag = argmax_lag |corr(lag)|`. If no lag has sufficient sample
size → `INSUFFICIENT_DATA`.

**Response magnitude.** At `best_lag`, with `m = n - best_lag` paired
observations and `direction ∈ {-1, 0, +1}` from the state waterfall:
```
response_magnitude = mean(receiver[best_lag : n]) × direction   (0.0 if direction == 0)
```

**Stability.** `half = m // 2`. `corr_older` = correlation on the first
`half` pairs, `corr_recent` = correlation on the last `half` pairs (same
best_lag pairing).
```
stability = clip(100 - 100×|corr_older - corr_recent| / 2, 0, 100)
```
`0.0` (not fabricated) if `half < 2`.

**Regime dependence.** For each regime value present in
`regimes[best_lag : n]` (the caller's own `ENUM_AX_REGIME_CLASS` tag per
observation): bucket correlation computed only if
`count ≥ min_regime_sample_size` (default 15), else reported as
`sufficient=False`, `correlation=0.0`. `strongest_regime` = the
sufficient bucket with the largest `|correlation|`, using **strict `>`**
against a `0.0`-seeded running maximum (never promoted at exactly `0.0`).

**Effective minimum association (post-audit-fix).**
```
significance_floor(n, L) = clip(z(1 - alpha/(2L)) × 1/sqrt(n-3), 0, 1)   [n≥4, else 1.0]
effective_min_association       = max(min_association, significance_floor(m, L))
effective_min_association_half  = max(min_association, significance_floor(half, L))   [half_has_enough, else 1.0]
```
where `L = maxLag + 1` (every scanned lag, eligible or not — see §2.4),
`z(p)` is the standard normal inverse CDF, `alpha` default 0.01,
`min_association` default 0.25. **This is the audit's fix**: prior to
this audit, both the full-sample and half-sample checks used the same
`effective_min_association` (computed from `m`); see §2/§10/§12.

**State waterfall** (exact order, first match wins; `half_has_enough =
half ≥ max(5, min_sample_size/4)`):
1. `!half_has_enough` → `INACTIVE` if `|corr_full| < eff_full` else `LEADER`
2. `|corr_older| ≥ eff_half AND |corr_recent| ≥ eff_half AND sign(corr_older) ≠ sign(corr_recent)` → `INVERTED`
3. `|corr_older| ≥ eff_half AND |corr_recent| < eff_half` → `DIVERGING`
4. `|corr_older| ≥ eff_half AND |corr_recent| < |corr_older| × weakening_ratio` → `WEAKENING`
5. `|corr_full| < eff_full` → `INACTIVE`
6. `strongest_regime is not None AND current_regime == strongest_regime` → `CONFIRMING`
7. else → `LEADER`

**Confidence.** `0.0` if state ∈ {INSUFFICIENT_DATA, INACTIVE, UNKNOWN}.
Else:
```
sample_factor    = clip(100×(m - min_sample_size) / (3×min_sample_size - min_sample_size), 0, 100)
strength_factor  = clip(100 × association_strength, 0, 100)
stability_factor = stability if half_has_enough else 50.0
confidence       = min(sample_factor, strength_factor, stability_factor)
confidence      *= 0.5   if state ∈ {DIVERGING, WEAKENING, INVERTED}
```
Gated minimum, never a weighted average.

**Stale-data detection.** `align_returns()`: a pair is dropped if either
close is non-positive, or either timestamp is in the future relative to
`now`, or (if configured) the pair's own timestamps differ by more than
`max_misalignment_seconds`. Separately, if `max_stale_seconds` is set,
**only the single most recent retained pair** is dropped if
`now - max(newest leader time, newest receiver time) > max_stale_seconds`
— historical age alone never invalidates earlier pairs.

**Timestamp alignment.** Index-based on a shared reference bar sequence
(leader's own bar-close time drives the MQL5 reference clock); lag is an
array-index offset, not a raw time computation. See §9.

---

## 2. Multiple-comparisons verdict

Traced against the 10 sub-questions:

1. **Exact hypotheses tested:** `L = maxLag + 1` (default 11: lags 0–10).
2. **Lag 0 included:** yes (`range(0, max_lag+1)`).
3. **Every lag a separate test:** yes, each is its own Pearson
   correlation on its own (overlapping) slice.
4. **Effective threshold accounts for lag count:** yes, via
   `significance_floor(n, L)`, `L` passed through explicitly.
5. **Additional selection after the lag search:** yes — the
   older/recent split is a second look at the same selected data (see
   §2.10 below, the defect this second look exposed).
6. **Regime-specific searches add multiple testing:** yes, up to 9
   buckets, `strongest_regime` is itself a best-of-N selection —
   **no significance correction is applied to this selection**. Traced
   impact: `strongest_regime`/`strongest_regime_correlation` are
   report-only fields plus the `CONFIRMING`-vs-`LEADER` label; they do
   **not** feed the confidence formula (confirmed by tracing every
   confidence input — sample_factor/strength_factor/stability_factor
   derive only from `corr_full`/`corr_older`/`corr_recent`). Real but
   narrow: affects only the state label, not the quantitative
   reliability signal. Documented as a limitation (§17), not fixed —
   see the Minimal-Change Principle discussion below.
7. **Positive and inverse as additional hypotheses:** no extra
   correction needed — `argmax |corr(lag)|` and the two-sided
   `z(1-alpha/(2L))` critical value already treat "positive or negative"
   as one bounded two-sided test per lag, not two separate ones. Traced
   and confirmed correct as implemented.
8. **Bonferroni, Šidák, or other:** Bonferroni (`alpha/L`, not
   `1-(1-alpha)^(1/L)`). Confirmed by direct code trace, matches the
   stated name.
9. **Implementation matches stated method:** yes, verified line-by-line.
10. **Applied consistently in every relevant state:** **NO — this was
    the audit's main finding.** `corr_older`/`corr_recent` are each
    computed on `half = m//2` observations, but the pre-audit code
    checked them against `effective_min_association` computed from `m`,
    the FULL sample. `significance_floor(half,...) ≈ 1.42×
    significance_floor(m,...)` at typical sizes (empirically confirmed:
    0.238 vs 0.168 at m≈395). **Fixed** — see §12 for the exact
    before/after reproduction.

**Verdict:** the Bonferroni correction itself is textbook-correct and
consistently *named*, but was inconsistently *applied* before this
audit (item 10). Fixed with the smallest defensible change: a second,
correctly-calibrated threshold computed from `half` instead of `m`,
used only for the three checks that actually operate on half-sample
data. Item 6 (regime-selection multiple testing) remains an honest,
documented, narrow limitation — not fixed, since it affects only a
report-only label, not the confidence/state's quantitative reliability.

## 3. Effective-sample-size verdict

Two distinct questions, both investigated:

- **Overlapping observations across DIFFERENT lag computations:** yes,
  by design — every lag's correlation reuses most of the same
  underlying data (lag 3 and lag 4 differ by one shifted observation out
  of ~400). This is exactly what the multiple-comparisons correction
  (§2) exists to address, and Bonferroni's bound is valid under
  arbitrary dependence between tests (it doesn't require independence,
  unlike Šidák) — so this does not additionally invalidate the
  correction, though it may still be conservative relative to the true
  dependence structure. Not separately correctable without a
  block-bootstrap null (see §15's own conclusion).
- **Serial dependence WITHIN a single correlation's own sample:** the
  `SE(r) ≈ 1/sqrt(n-3)` formula assumes IID returns. Real financial
  returns exhibit autocorrelation (bid-ask bounce, short-term momentum).
  **Empirically tested** (§15): AR(1) noise at φ=0.3 raised the
  false-positive rate from 0.60% (IID) to 1.40%; φ=0.5 to 2.00%, at
  n=400 where the flat `min_association=0.25` floor still dominates for
  most of the range. This is a real, quantified, but modest effect at
  realistic autocorrelation levels — not a coding defect, an assumption
  mismatch inherent to using a closed-form Gaussian SE formula at all.

**Verdict:** the implementation does **not** model effective sample size
under serial dependence — documented here precisely, per the audit's own
instruction not to invent an uncorrectable correction. A rigorous fix
(block-bootstrap null calibration) was considered and rejected as
disproportionate to the measured effect size and against the phase's own
"clean statistical layer, not a research project" instruction.

## 4. Best-lag selection-bias verdict

Constructed a synthetic experiment (fresh seeds, independent RNG,
n=400, true relationship injected at a known lag=5) at two true
strengths:

| True corr | Detected | Correct lag (of detections) | Reported strength (mean) | Bias |
|---|---|---|---|---|
| 0.30 (well above floor) | 445/500 (89.0%) | 445/445 (100%) | 0.315 | **+0.015 (+5%)** |
| 0.20 (near floor) | 152/500 (30.4%) | 152/152 (100%) | 0.287 | **+0.087 (+43%)** |

The lag/direction is reliably correct once detected (100% in both
cases) — the bias is in the *magnitude*, not the lag or sign, and grows
sharply as the true relationship approaches the detection threshold
(classic "winner's curse"/selection-filter bias, a property of any
threshold-crossing selection, not unique to this code).

**Does the existing floor protect against it?** Checked directly:
confidence for the near-threshold (true corr 0.20) detections was
**mean 19.0, max 35.3** — never remotely close to "high confidence."
For the well-above-floor case (0.30), confidence was still modest (mean
28.4) because `strength_factor = 100 × |r|` treats realistic financial
correlations (rarely above ~0.5) as inherently capping confidence — an
intentional design property (see §7), not a bug.

**Verdict:** selection bias is real, measured, and not eliminated — but
substantially mitigated by the existing confidence gate, which already
keeps near-threshold detections at low confidence by construction. Per
the audit's own menu (corrected threshold / holdout / discovery-
validation split / shrinkage / minimum effect size) and its own
instruction not to add complexity unless justified: no further change
made. **Documented as a limitation**, not fixed — see §17 and both
files' updated headers.

## 5. Stability verdict

`stability = 100 - 100×|corr_older - corr_recent|/2` — a symmetric
measure of how much the correlation moved between the two halves, using
the SAME paired data the best-lag selection already used (not
independent evidence, and not claimed to be — both files' comments
already say "gated minimum of independent evidence factors," and
stability genuinely is a different statistic — sign/magnitude change —
computed from overlapping but transformed data, not "repeated agreement
within the same evidence" in a circular sense).

Five scenarios traced against the actual code:

| Scenario | Expected | Actual (traced/tested) |
|---|---|---|
| A. Stable throughout | high stability, LEADER/CONFIRMING | Confirmed (tests 1/2/4/5) |
| B. Collapse to random | stability drops, DIVERGING | Confirmed (test_7, stability < 80) |
| C. Sign inversion | stability drops sharply, INVERTED | Confirmed (test_8) |
| D. Alternating +/-/+/- | ambiguous — see below | Not a named state; falls to whichever half-vs-half comparison lands on (see finding below) |
| E. Volatility-only change, same direction | stability should stay high (direction unchanged) | Correct by construction — stability only reads correlation SIGN/magnitude, not volatility scale (log returns are scale-normalized) |

**Finding (not a defect, a genuine coverage gap):** scenario D-like data
(a relationship that is weak in the older half and only becomes strong
in the recent half — the mechanism behind the outlier false-LEADER case
in §14) has **no dedicated state**. The waterfall's asymmetry (rich
handling for "was strong, now weak" via DIVERGING/WEAKENING; nothing for
"was weak, now strong") means such cases fall through to plain `LEADER`.
Traced its practical impact: `stability` for such cases is genuinely
reduced (confirmed 48.75 in the single-outlier case), and since
`stability_factor` feeds the confidence gate, this **is** reflected in a
depressed confidence score — the state label doesn't name the asymmetry,
but confidence isn't blind to it either. Documented, not fixed (adding a
9th state was judged disproportionate to a case already substantially
mitigated by confidence).

## 6. Regime-dependence verdict

Deterministic sparse-sample test constructed: 397 observations tagged
regime 1, 3 tagged regime 2 (`min_regime_sample_size=15`).

```
Regime 2 (n=3):   RegimeBucketResult(regime=2, correlation=0.0, sample_count=3, sufficient=False)
Regime 1 (n=397): RegimeBucketResult(regime=1, correlation=0.146, sample_count=397, sufficient=True)
strongest_regime = 1 (only from the sufficient bucket)
```

**Insufficient evidence stayed insufficient evidence** — correlation
reported as `0.0` (not fabricated), `sufficient=False`, never promoted
to `strongest_regime`. No confidence inflation from a 3-observation
bucket. **PASS**, no defect found. (The multiple-testing concern within
regime bucketing itself is covered under §2 item 6, not repeated here.)

## 7. Confidence-calibration verdict

Every component traced (see §1's exact formula). None of the five
required adversarial tests found a violation:

- **Strong association + tiny sample:** `sample_factor` scales linearly
  from 0 at `min_sample_size` to 100 at `3×min_sample_size` — a tiny
  sample is hard-capped regardless of strength. Confirmed by formula
  trace; `min()` gate prevents strength from compensating.
- **Strong association + large clean sample:** confidence can reach
  high values — confirmed empirically (test_1/test_2/test_4/test_5 all
  produce `association_strength > 0.9`, `sample_factor=100` at
  `m≈300-400`, giving confidence in the 90s where stability also holds).
- **Weak association + huge sample:** `strength_factor` stays low
  regardless of sample size — this is the intentional design already
  discussed in §4 (distinguishes statistical detectability from
  practical strength, exactly as this item requires).
- **Stable historical relationship + recent breakdown:** confirmed via
  test_7 — DIVERGING/WEAKENING states apply the explicit ×0.5 penalty
  on top of the already-reduced `strength_factor`/`stability_factor`.
- **Strong correlation + poor data quality:** `dataQualityOk` (MQL5) /
  the `n < min_sample_size` early return (Python) gate confidence to
  `0.0` outright before any strength/stability computation runs —
  confirmed by code trace, this is a hard gate, not a soft penalty.

**Never described as a probability anywhere** — confirmed by grep
(§18). **Verdict: PASS.** No defect found; confidence behaves as a
gated, conservative, non-probabilistic reliability signal exactly as
documented.

## 8. Response-magnitude/unit verdict

Computed exclusively from `log(close[t]/close[t-1])` — log returns,
scale- and price-level-invariant by construction. A 1% move in XAUUSD
(~$650 at $65,000... i.e. a realistic ~$20 move on ~$2,000 gold) and a 1%
move in EURUSD (~0.0110 on ~1.10) produce the **same** log-return
magnitude (~0.00995) and are therefore directly comparable — no unit
mismatch is possible by the calculation's own structure, confirmed by
inspection (no raw price, no ATR-normalization, no mixed units anywhere
in the response-magnitude formula). **Verdict: PASS.**

## 9. Timestamp/alignment verdict

Traced exactly (§1). For lag ≥ 0: leader read at index `i-lag` (at or
before receiver's own index `i`), never after. Adversarial tests run:

| Test | Result |
|---|---|
| A. Perfect known 3-bar lead | `test_1`/`test_5`: exact lag recovered |
| B. Receiver moves first | equivalent to a negative-true-lag case; not directly testable within `[0,maxLag]` by design — the engine only searches non-negative lags (leader precedes or is concurrent with receiver), consistent with the "leader"/"receiver" naming; a caller wanting to test the reverse direction swaps which symbol is passed as leader vs receiver — confirmed this is a deliberate scope choice, not a bug, and is exactly what `test_3_no_relationship`'s independent-series construction indirectly covers (no false lead-lag manufactured in either direction) |
| C. Equal timestamp, incomplete receiver bar | out of `align_returns`'s own scope — bar-completeness is enforced one layer up, in the MQL5 `Sample()`'s own `CopyClose(..., shift=1, count=2, ...)` convention (only ever reads bars at shift≥1, i.e. already-closed) before any return is computed; `align_returns` itself assumes its caller already filtered to closed bars — confirmed by design, documented in the file header |
| D. Missing leader bar | `test_9_missing_data` + `haveLeader` gate in MQL5 `Sample()`: pair dropped, no fabrication |
| E. Missing receiver bar | same as D, `haveReceiver` gate |
| F. Irregular timestamps | `test_11_timestamp_misalignment`: deterministic, tolerance-gated, re-tested here (§ below) with duplicate timestamps and a 2-day weekend-style gap — **no crash, correct pair count, no special-casing needed** |
| G. Weekend/market-closure gap | tested directly (this audit): a 2-day gap inserted mid-series produced no crash and the expected pair count — large `datetime` gaps are handled by the same arithmetic as any other timestamp difference, no special code path required |
| H. Duplicate timestamp | tested directly (this audit): a duplicate timestamp at one index produced no crash and the expected pair count |
| I. Future receiver observation inserted deliberately | `test_12_lookahead_trap`: constructs `receiver[i] = leader[i+1]` (a deliberately planted look-ahead relationship) — engine reports `INACTIVE`, no lag recovers it |

**Verdict: PASS.** No look-ahead path found; all nine named scenarios
produce correct, non-crashing, non-fabricating behavior.

## 10. Staleness verdict

Exact definition (§1): staleness applies **only** to the single most
recent retained pair, comparing `now` against that pair's own newest
timestamp — historical age is never itself grounds for rejection.
Confirmed: `test_10_stale_data` shows a fresh call retains `n-1` pairs,
and pinning `now` far in the future drops exactly the single most recent
pair (`n-2` remain), not the whole history. **Verdict: PASS**, matches
the documented convention precisely; this was itself the subject of an
earlier fix (before this audit) and the audit re-confirmed it rather
than re-discovering a problem.

## 11. Divergence-waterfall verdict

Exact order given in §1. Adversarial reconstruction of the specific
scenario the authorization names (full-window correlation ≈0 via sign
cancellation, older strongly positive, recent strongly negative):
confirmed via `test_8_relationship_inversion` — `INVERTED`, not
`INACTIVE`, because the older/recent checks run **before** the
`corr_full`-based `INACTIVE` gate (this exact ordering was itself a
pre-4A-audit fix, re-verified here, not re-broken).

Additional named transitions checked: positive→weak (`DIVERGING`,
test_7), strong→absent (`DIVERGING`), positive→negative
(`INVERTED`, test_8), stable→unstable (stability score drops,
confirmed via the outlier experiments in §14). Every state has an exact
numeric definition (§1) with no overlapping ambiguous branches —
confirmed by tracing the waterfall as a strict if/elif chain with no
state reachable by more than one condition.

**Verdict: PASS**, with the one coverage gap already noted in §5
(no dedicated "emerging" state for weak→strong) — documented, not
blocking.

## 12. False-positive experiment

**Exact reproduction, fresh seeds (100000+ range, never previously
used), independent RNG per trial, no seed selection after observing
outcomes:**

| Config | n | max_lag | threshold | trials | false positives | rate |
|---|---|---|---|---|---|---|
| Original 4A claim (pre-fix, historical) | 400 | 10 | flat 0.15 | 100 | 22 | 22.0% |
| Original 4A claim (pre-fix, historical) | 400 | 10 | flat 0.25 | 100 | 0 | 0.0% |
| **Pre-audit-fix**, exposing the new defect | 200 | 10 | corrected (buggy half-application) | 2000 | 162 | **8.10%** |
| **Post-audit-fix** | 200 | 10 | corrected (fixed) | 2000 | 21 | **1.05%** |
| Post-fix, n=400 (matches original config) | 400 | 10 | corrected | 300 | 1 | 0.33% |
| Post-fix, n=100 (stress) | 100 | 10 | corrected | 2000 | 18 | 0.90% |
| Post-fix, n=500 (engine default capacity) | 500 | 10 | corrected | 300 | 1 | 0.33% |

"False positive" = any state other than `INACTIVE`/`INSUFFICIENT_DATA`
on genuinely independent (unrelated) series.

**This DOES differ materially from the previously-reported 0/300** — the
n=200 case was never tested before this audit; the original report's
0/300 was run at n=400/500 only, where the defect happened to be masked
by the flat floor. The audit's own investigation (§2.10) explains
exactly why: the previous check's sample size was too large to expose
the sub-window threshold bug. This is now covered by a permanent
regression test (`test_13_subwindow_significance_floor_regression`,
locked at n=200).

## 13. Sensitivity/power characterization

From §4's experiment (not re-tabulated): at n=400, max_lag=10, true
lag=5, true correlation 0.30 → detected in 89.0% of trials, correct lag
in 100% of detections. At true correlation 0.20 (near the floor) →
detected in only 30.4% of trials (power drops sharply as strength
approaches the significance floor, as expected for any threshold-based
detector) but still 100% correct-lag when detected. **No optimization
was performed against these numbers** — they are reported as
characterization, not tuned to look good, per the audit's own
instruction.

## 14. Outlier robustness

**Confirmed real, serious effect — the audit's most significant
non-fixed finding.**

| Scenario | State | Strength | Confidence |
|---|---|---|---|
| Clean, genuinely unrelated (n=400) | INACTIVE | 0.086 | 0.0 |
| +1 co-moving outlier (0.25% of data) | **LEADER** | 0.785 | 48.7 |
| +4 co-moving outliers, spread across the window (1% of data) | **LEADER** | 0.936 | **93.6** |
| +1 one-sided outlier (leader only, receiver unaffected) | INACTIVE | 0.104 | 0.0 |

The one-sided control confirms it's specifically co-movement (not mere
magnitude) driving the effect — exactly as Pearson correlation's known
leverage sensitivity predicts. The 4-outlier case is the concerning one:
outliers spread evenly across the older/recent split make `stability`
read as high (99.5) because both halves are equally "corrupted," so the
stability check provides **no** protection in that specific
distribution.

**Not fixed** — see the reasoning recorded in both files' headers and
§4/§17: winsorizing was considered and rejected because (a) the audit's
own instruction explicitly warns against blind clipping without
distinguishing legitimate shocks from corrupt data, a judgment this
module cannot make from return values alone, and (b) data-quality
screening is this codebase's `CDataIntegrityEngine.mqh`'s established
responsibility, not something to duplicate per-engine (§19 rule 8).
**Documented as the highest-priority known limitation**, with the exact
numbers above, in both file headers and this report.

## 15. Null-model diversity

Tested beyond plain IID Gaussian (n=400, max_lag=10, 500 trials each,
fresh seeds):

| Null structure | False-positive rate |
|---|---|
| IID Gaussian (baseline) | 0.60% |
| AR(1), φ=0.3 (mild autocorrelation) | 1.40% |
| AR(1), φ=0.5 (stronger autocorrelation) | 2.00% |
| GARCH-like volatility clustering | 0.20% |

Autocorrelated nulls show a real, monotonic, but modest elevation
(consistent with §3's theoretical concern about the IID assumption
behind `SE(r)`). Volatility clustering alone (without serial mean
dependence) shows no material effect, since Pearson correlation itself
doesn't assume homoskedasticity. **Verdict:** the statistical gate
remains reasonably defensible under realistic non-IID nulls at these
magnitudes — documented as a quantified, not hidden, limitation (§3).

## 16. Python/MQL5 equivalence

MQL5 cannot be executed in this environment (§21) — equivalence was
checked by direct line-by-line trace of both files against each other,
not dual execution. Checked: lag indexing (`leaderWindow[0:n-lag]` vs
`receiverWindow[lag:n]` — identical), the older/recent split (identical
offsets), the state waterfall (identical branch order and conditions,
post-fix identical use of `effectiveMinAssociationHalf`), confidence
formula (identical), missing/stale-data handling (`haveLeader`/
`haveReceiver`/`dataIntegrityOk` gates mirror `align_returns`'s checks),
regime-bucket tie-break (fixed to strict `>` matching Python during
Phase 4A's own original review, re-confirmed here), and
`NormalInverseCdf`/Acklam's approximation (a standard, independently-
known algorithm, not something whose correctness depends on matching
`scipy.stats.norm.ppf` bit-for-bit — both are accurate approximations to
the same well-defined mathematical function). **No semantic divergence
found** in this trace. The one-line-per-fix discipline used throughout
this phase (apply the identical fix to both files, verify the MQL5 diff
is minimal via code review) is the closest available substitute for
side-by-side execution given the compiler constraint.

## 17. Computational assessment

Re-confirmed, not re-litigated: bar-level only (`Sample()` no-ops except
on a new leader bar); bounded ring buffer (`m_capacity`, default 500);
bounded lag range (`m_maxLag`, default 10); regime-bucket loop is
`O(9 × m)` — the `9` is `ENUM_AX_REGIME_CLASS`'s fixed member count, not
data-size-dependent. No full-history rescans, no per-tick recomputation
beyond the new-bar gate. No change from Phase 4A's own original
assessment; the audit's own fix (an added `SignificanceFloor` call using
`half` instead of `m`) is `O(1)` extra work per `Sample()` call, not a
complexity regression.

## 18. Documentation/claim-honesty assessment

Grepped both source files and the Phase 4A report for
`predict|guarantee|profit|alpha|exploit|edge` — every match is either
part of an explicit **denial** ("does not claim...", "never claim...")
or an unrelated identifier (`m_significanceAlpha`, the Bonferroni `alpha`
parameter — a standard statistics term, not a trading-alpha claim).
"Predictive Association" appears exactly once, as the authorization's
own approved terminology. **No causal language found anywhere.**
**Verdict: PASS**, confirmed by direct search, not assumed.

## 19. Defects discovered and fixes

**Defect 1 (the only code defect found and fixed):**

- **Evidence:** §2.10, §12 — 8.10% false-positive rate at n=200 (1000+
  trials, later reproduced at 2000 trials), versus ~1% at the same
  sample size after the fix.
- **Root cause:** `corr_older`/`corr_recent` are computed on `half =
  m//2` observations but were compared against a threshold
  (`effective_min_association`) calibrated for the full `m`-observation
  sample. The true noise floor for a half-sized sample is ~1.4× larger.
- **Fix:** added `effective_min_association_half` (Python) /
  `effectiveMinAssociationHalf` (MQL5), computed via
  `significance_floor(half, L)` instead of `significance_floor(m, L)`,
  used for exactly the three checks that operate on half-sample data
  (INVERTED/DIVERGING/WEAKENING). The `corr_full`-based checks
  (INACTIVE gate, the `!half_has_enough` fallback) continue to use the
  original `m`-calibrated threshold, unchanged.
- **Regression result:** all 14 pre-existing Phase 4A tests still pass;
  new regression test `test_13_subwindow_significance_floor_regression`
  added and passes (locks the false-positive rate at n=200 below 5%,
  generously above the observed ~1% to avoid flakiness while still
  catching a real regression); full suite 42/42 passing; MQL5 file
  balance-checked clean and code-reviewed clean (no new findings); full
  repo 61/61 files balance-check clean; zero references to the engine
  in the live EA (unchanged); zero QQQ/TQQQ/NDX/NQ (unchanged).

**No other code defects were found.** Three further findings were
investigated, quantified, and **deliberately not fixed**, per the
Minimal-Change Principle's own instruction that "every modification
must be justified by a discovered defect" and its explicit caution
against unjustified complexity/winsorizing:

- Outlier sensitivity (§14) — a real, high-magnitude effect, but the
  defensible fix (data-quality screening) belongs in
  `CDataIntegrityEngine.mqh`, not duplicated here, and the audit's own
  instruction explicitly warns against blind clipping.
- Selection/threshold bias near the detection floor (§4) — an inherent
  property of best-of-N threshold selection, already substantially
  mitigated by the existing confidence gate (empirically confirmed).
- Regime-bucket selection's own lack of a significance correction (§2.6)
  — real but narrow (affects only a report-only label, not confidence).

All three are now explicitly documented in both source files' headers
and this report, with exact numbers, so they are visible to any future
reader rather than silently present.

## 20. Final disposition

**B. PASS WITH LIMITATIONS.**

The one material, high-confidence-inflating correctness defect found
(the sub-window significance-floor mismatch, §2.10/§12/§19) has been
fixed with the smallest defensible change, verified with fresh seeds
across five sample sizes, and locked in with a permanent regression
test. No other correctness defect was found across 19 audit angles,
each backed by an actual experiment or a direct code trace, not
assumption.

Real, quantified statistical limitations remain and are now explicitly
documented rather than hidden: outlier sensitivity (the most significant
of these — a handful of coincident extreme observations can
manufacture high confidence), selection/threshold bias near the
detection floor, non-IID null degradation under serial dependence, and
an unaccounted-for multiple-testing exposure in regime-bucket selection
specifically. None of these are coding mistakes; they are inherent
properties of the chosen statistical method (Pearson correlation,
best-of-N lag selection, Bonferroni correction) applied honestly rather
than concealed.

**Nothing was manufactured.** Every number in this report came from an
actual test run or a direct trace of the actual code, dated to this
audit.

---

## 21. Compilation honesty

**MQL5 compilation not verified because no actual MQL5 compiler was
available in this environment.** Balance-check (brace/paren/bracket)
and code review (static, line-by-line trace against the tested Python
reference) are the verification methods used for the MQL5 file, per
this build environment's standing constraint (unchanged since Phase 1).
Neither is treated as a substitute for compilation, and no compilation
claim is made anywhere in this report.

## 22. Regression results after the fix (final state only)

```
$ python3 -m pytest python/tests/test_lead_lag.py -v
15 passed in ~1.3s   (14 pre-existing + 1 new regression test)

$ python3 -m pytest python/tests/ -q
42 passed in ~3.5s   (41 pre-existing + 1 new)

$ python3 balance_check.py <all 61 MQL5 files>
0 mismatches - every file OK (balanced)

$ grep InformationTransmissionEngine AutopsyX_FlipDemon_Extreme.mq5
(zero matches - still not wired)

$ grep -i "QQQ|TQQQ|NDX|NQ" <all touched files>
(zero matches)
```

All results above are from the **final, post-fix state** — no
pre-fix result is reported as current anywhere in this document.

**Files modified by this audit:**
`python/autopsy_research/lead_lag.py` (fix + header documentation),
`MQL5/Include/AutopsyX/InformationTransmissionEngine.mqh` (identical
fix + header documentation), `python/tests/test_lead_lag.py` (one new
regression test). No other file touched. No entry/risk/execution/
management/journal/ICT/VWAP/VP-MACD/liquidity/news-defense behavior
modified — confirmed by `git status` showing only these three files.
