# Phase 5: Information Value, Ablation, Redundancy Detection and Incremental Predictive Validation

**Scope:** real-data research only. No trading logic, no risk logic, no
execution, no MQL5 production integration, no adaptive learning, no
modification to any prior phase's own code. All code lives under
`research/information_value/`; nothing in it is imported anywhere in
`MQL5/Experts/` (verified by repo-wide grep, §20 below).

---

## 1. Research question

Does each intelligence layer already built (Market State, Regime,
Volatility/Seriality, Information Transmission, Shock DNA) contribute
information that cannot already be explained by the layers preceding it?
No answer was assumed going in; KEEP, REDUNDANT, UNSTABLE, INSUFFICIENT
EVIDENCE, and KILL were all treated as legitimate outcomes.

## 2. Data source

Alpha Vantage MCP connector, two series: `GOLD_SILVER_HISTORY` (symbol=XAU,
daily) and `FX_DAILY` (EUR/USD, daily). Both retrieved live during this
phase and saved verbatim for reproducibility - see
`research/information_value/data/`.

## 3. Data provenance

Full record in `docs/PHASE5_DATA_PROVENANCE.md`. Summary: XAUUSD is
**close-price-only** (no OHLC) and 26% of its raw rows are weekend-dated
with a pattern (small Fri→Sat drift, then an exact Sat→Sun plateau)
consistent with an interpolated construction, not raw executed trades -
those rows are dropped before any analysis. EUR/USD is genuine OHLC, 0
inconsistent rows out of 5,000. EUR/USD is used as an **exploratory cross-
asset proxy only** - not DXY, not a USD-strength index, not asserted to be
the canonical gold/USD relationship (`scope.py::EUR_USD_PROXY_DISCLAIMER`).

## 4. Dataset quality

- XAUUSD: 5,408 raw rows → 3,998 after dropping 1,410 weekend rows and 0
  duplicates.
- EUR/USD: 5,000 rows, 0 OHLC-inconsistent rows.
- Joint (inner-joined on date): **3,997 rows**.
- All prices > 0 verified; all OHLC consistency constraints verified for
  EUR/USD; log returns computed causally (first row of any series is NaN,
  never fabricated as 0).

## 5. Sample period

2011-06-01 to 2026-09-25 (the full joint-sample window).

## 6. Development / validation / OOS split

Fixed 60/20/20 chronological split, dates fixed **before** any result was
examined (`splits.py`):

| Split | Dates | Rows |
|---|---|---|
| DEV | 2011-06-01 – 2020-08-10 | 2,398 |
| VAL | 2020-08-11 – 2023-09-01 | 799 |
| OOS | 2023-09-04 – 2026-09-25 | 800 |

No random shuffling anywhere. Model coefficients are fit on DEV only and
frozen; VAL/OOS are evaluation-only.

## 7. Target definitions

Pre-registered before any test (`targets.py`), chosen from data granularity
alone: H1=1, H2=5, H3=20 trading days. `fwd_ret_norm_H{n} = log(price[t+H]/
price[t]) / realized_vol(t)`, where `realized_vol(t)` is a 20-day trailing,
strictly causal rolling stdev of log returns (a documented **proxy** for
ATR-relative normalization - not real ATR, since no OHLC exists for XAU).

## 8. Baseline

**A_baseline** = `xau_log_return` alone (Market State reduced to the one
field reconstructible from close-only data - every other MarketStateEngine
field needs true range or tick-level microstructure data this dataset
never had - `scope.py`).

## 9. Ablation matrix (REDUCED - see §16/§22 for why)

| Model | Features |
|---|---|
| A_baseline | xau_log_return |
| B_volatility_seriality | + return_autocorr, directional_persist, reversal_frequency |
| C_transmission | + transmission_assoc_signed, transmission_confidence |

OLS, fit on DEV, frozen coefficients applied to VAL/OOS (`ablation.py`).

## 10. Information coefficients

Full model-level table (VAL/OOS only - DEV is in-sample fit quality, never
quoted as evidence):

| Model | Target | Split | Pearson IC | Spearman IC | Dir. accuracy |
|---|---|---|---|---|---|
| A_baseline | H1 | VAL | 0.005 | -0.036 | 0.498 |
| A_baseline | H1 | OOS | 0.011 | 0.010 | 0.533 |
| B_volatility_seriality | H1 | OOS | 0.042 | 0.045 | 0.513 |
| C_transmission | H1 | OOS | 0.043 | 0.021 | 0.536 |
| B_volatility_seriality | H2 | OOS | 0.066 | 0.068 | 0.536 |
| C_transmission | H2 | OOS | 0.049 | -0.023 | 0.532 |
| C_transmission | H3 | OOS | -0.080 | **-0.168** | 0.509 |

The H3/OOS/C_transmission cell's naive Spearman p-value is 2.4×10⁻⁶ - see
§17 for why this is **not** trustworthy as reported.

## 11. Effect sizes

All observed |Spearman IC| values in the real-data ablation are small
(0.02–0.17). No cell shows an effect size that would be considered large
by any conventional standard even before correction.

## 12. Redundancy analysis

Full pairwise table: `research/information_value/results/phase5_redundancy_oos.csv`.
Notable pairs: `return_autocorr` ↔ `directional_persist` MODERATE (Pearson
-0.31); `return_autocorr` ↔ `transmission_assoc_signed` **MODERATE**
(Pearson 0.36, Spearman 0.30). All other pairs LOW. The two features that
reached PARTIALLY SUPPORTED status (§17) are themselves moderately
correlated with each other - the apparent incremental value of adding
transmission features on top of the return-serial ones is not from two
fully independent sources.

## 13. Regime analysis

**BLOCKED**, not attempted. `RegimeClassifierEngine`'s real classification
needs ATR (`m_volRatio = currentATR/avgATR`), which this close-only dataset
cannot supply. Building any substitute (even a simple moving-average
trend/regime splitter) would itself be a new, competing regime taxonomy -
explicitly forbidden. Disposition: **INSUFFICIENT EVIDENCE (real-data)**,
same status as Shock DNA.

## 14. Volatility analysis

Conditioned the two PARTIALLY SUPPORTED candidates on **realized-vol
terciles** (a quantile split of the existing causal `realized_vol` column,
not a new taxonomy, not CVolatilityEngine's own state classification):

| Feature | Bucket | n | Spearman IC | Block-perm p |
|---|---|---|---|---|
| return_autocorr | GLOBAL | 795 | 0.143 | 0.0375 |
| return_autocorr | LOW | 267 | 0.190 | 0.0850 |
| return_autocorr | MID | 266 | 0.100 | 0.3350 |
| return_autocorr | HIGH | 262 | 0.116 | 0.2600 |
| transmission_assoc_signed | GLOBAL | 795 | 0.112 | 0.0900 |
| transmission_assoc_signed | LOW | 267 | 0.082 | 0.4590 |
| transmission_assoc_signed | MID | 266 | 0.101 | 0.3360 |
| transmission_assoc_signed | HIGH | 262 | 0.108 | 0.2945 |

Neither feature shows a relationship that holds uniformly across
volatility regimes - both weaken once split, and no single tercile
reaches the global result's own (already weak) strength.

## 15. Transmission analysis

Information Transmission (via `lead_lag.py`'s own `compute_snapshot()`,
called directly, not reimplemented) is the only real-data-testable
cross-asset layer. Its incremental contribution over
B_volatility_seriality is inconsistent across horizons: essentially flat
at H1, weaker than B alone at H2, and the one large-looking H3 effect is
the specific finding shown in §17 to be a block-permutation false
positive (empirical p=0.15, not 2×10⁻⁶). No evidence in this analysis
that Transmission adds real, stable incremental value beyond
Volatility/Seriality at daily granularity on EUR/USD↔XAU specifically.

## 16. Shock DNA analysis

**BLOCKED**, not attempted, per standing agreement. Shock DNA's onset
detection and range_expansion_atr are both true-range-based by definition
(Phase 4B's own primary formula) and cannot be faithfully reconstructed
from close-only XAUUSD. Disposition: **INSUFFICIENT EVIDENCE (real-data)**.
No approximation of ATR was substituted under the engine's name.

## 17. Null testing

The single most important methodological finding of this phase. Naive
scipy parametric p-values assume IID observations; `targets.py`'s own
H2/H3 targets are built from **overlapping** windows (H3's 20-day window
shares 19 days with its neighbor), which inflates apparent significance.
Caught directly: `C_transmission`/H3/OOS showed naive Spearman p=2.4×10⁻⁶,
but under a **block-permutation** null (block_size=21, respecting the
overlap so no permuted block fabricates new structure, 2,000 permutations)
the empirical p-value is **0.15** - not distinguishable from noise. Every
p-value used for classification in this phase is the block-permutation
one, never the naive parametric one alone (`permutation.py`).

## 18. Multiple-testing controls

Benjamini-Hochberg FDR (`multiple_testing.py`), applied across the full
54-hypothesis battery (3 models + 6 individual features × 3 horizons × 2
splits): **0 of 54 hypotheses survive FDR correction at α=0.05.** 5 reach
PARTIALLY SUPPORTED (block-permutation p<0.10, does not survive
correction): `return_autocorr`/H1/OOS, `return_autocorr`/H2/OOS,
`transmission_assoc_signed`/H2/OOS, `A_baseline`/H3/VAL,
`xau_log_return`/H3/VAL (the last two are the same underlying feature under
two different labels). Full ledger:
`research/information_value/results/phase5_research_ledger.csv`.

## 19. Outlier robustness

1st/99th-percentile winsorization applied to both PARTIALLY SUPPORTED
candidates: `return_autocorr` Spearman 0.1428→0.1427; `transmission_
assoc_signed` 0.1119→0.1120. Negligible change - neither result is
outlier-driven.

## 20. Temporal robustness

Six sequential ~2.5-year windows across the full 2011–2026 span, testing
`return_autocorr` vs. `fwd_ret_norm_H2`: Spearman **+0.22, -0.18, -0.01,
+0.04, +0.09, +0.11**. The relationship's sign flips entirely between the
first two windows and stays weak/inconsistent afterward - not a stable,
time-independent relationship.

## 21. Walk-forward results

The frozen-DEV-coefficient VAL/OOS evaluation (§9/§10) is itself a form of
walk-forward discipline (coefficients never refit on evaluation data).
Combined with §20's sub-period breakdown, the evidence points the same
way: no model or feature in this reduced ablation shows a consistent,
time-stable relationship to any forward target.

## 22. Limitations

1. **DAILY, not M15.** Every result here is evidence about XAUUSD/EURUSD
   behaviour at daily granularity. It is explicitly **not** evidence about
   the live M15 intraday system (`scope.py::DAILY_SCOPE_DISCLAIMER`) - no
   extrapolation is made anywhere in this report.
2. **XAUUSD has no OHLC.** Market State's range/gap/ATR fields, Regime's
   ATR-gated classification, `CVolatilityEngine`'s state taxonomy, and
   Shock DNA are all untested against real data - not silently dropped,
   explicitly carried forward as INSUFFICIENT EVIDENCE (real-data).
3. **EUR/USD is an exploratory proxy**, not DXY, not validated as *the*
   gold/USD relationship.
4. **realized_vol is a proxy for ATR**, never presented as ATR itself, and
   never fed into Shock DNA or `CVolatilityEngine` under their real names.
5. **Confidence weights were not retuned** (standing decision preserved).
6. Only two candidate FX pairs/instruments were used throughout - no
   expansion of the instrument universe was made to chase a result.

## 23. Research ledger

`research/information_value/results/phase5_research_ledger.csv` - all 54
hypotheses, none deleted, each with naive p, block-permutation p, q-value,
FDR-rejection flag, and final decision.

## 24. Final disposition

**Per-layer classification** (§30 - no ranking, no "winner", no overall
score):

| Layer | Classification |
|---|---|
| Market State (reduced to raw return) | NOT SUPPORTED (real-data) |
| Regime | INSUFFICIENT EVIDENCE (real-data) - blocked by missing OHLC |
| Volatility/Seriality (return-serial sub-metrics) | UNSTABLE (real-data) - fails FDR, flips sign across sub-periods |
| CVolatilityEngine state taxonomy | INSUFFICIENT EVIDENCE (real-data) - blocked by missing OHLC |
| Information Transmission | NOT SUPPORTED (real-data) - one apparent H3 effect was a block-permutation false positive |
| Shock DNA | INSUFFICIENT EVIDENCE (real-data) - blocked by missing OHLC, per standing agreement |

None of these classifications should be read as a judgment on the live
M15 system (§22.1). They characterize what this specific daily, close-only
real dataset can and cannot support.

---

## PHASE 5 STATUS

```
Data source discovered:            YES
Real XAUUSD data obtained:         YES (close-only, no OHLC)
FX data obtained:                  YES (EUR/USD, full OHLC)
Data quality:                      PASS (with documented weekend-row exclusion)
Historical coverage:               2011-06-01 to 2026-09-25 (~15.3 years)
Rows:                              3,997 joint rows
Timeframe:                         DAILY (explicitly not M15 - see Limitations §1)
Development period:                2011-06-01 to 2020-08-10 (2,398 rows)
Validation period:                 2020-08-11 to 2023-09-01 (799 rows)
OOS period:                        2023-09-04 to 2026-09-25 (800 rows)
Python tests:                      50 new (this phase) / 136 total repo-wide, all passing
Leakage tests:                     PASS (explicit future-injection tests in
                                    targets.py, feature_construction.py)
Ablation:                          COMPLETE (reduced matrix - A/B/C, see §9/§16)
Redundancy:                        COMPLETE
Null testing:                      COMPLETE (block-permutation, catches a
                                    real false positive - see §17)
Multiple-testing audit:            COMPLETE (Benjamini-Hochberg FDR, 54 hypotheses,
                                    0 survive)
Walk-forward:                      COMPLETE (frozen-coefficient VAL/OOS +
                                    6-window temporal-stability check)
MQL5:                              NOT STARTED (correctly so - no real-data
                                    evidence of incremental information to
                                    justify porting, per the authorization's
                                    own §35)
Live coupling:                     ZERO (verified by repo-wide grep)
Real-market information-value conclusion:
  At DAILY granularity, on this specific real dataset, none of the
  currently-reconstructible feature families (raw return, Volatility/
  Seriality's return-serial metrics, Information Transmission) show
  incremental predictive information that survives block-permutation
  null testing and Benjamini-Hochberg correction across the full 54-
  hypothesis battery. One apparent strong effect (Information
  Transmission at the 20-day horizon) was traced to a specific,
  identified statistical artifact (overlapping-window autocorrelation
  inflating a naive p-value) and does not survive proper correction.
  Regime, CVolatilityEngine's taxonomy, and Shock DNA remain UNTESTED
  against real data, blocked by the lack of true-range XAUUSD data -
  this is an open question, not a negative finding, for those three.
Known limitations:                 See §22 above in full.
Commit:                            (filled in via follow-up commit)
```

## Hard stop

Per the authorization: no Phase 6, no machine learning, no ensemble, no
wiring into trading, no modification to live decision logic. Waiting for
explicit approval before any further phase.
