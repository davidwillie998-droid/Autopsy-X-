# Phase 3C Statistical Report

Contract hash `a317239dfc492486657b55f8980c463559de37edef95af21b5247420a4aee527` (version `3b.1`, unchanged from Phase 3B). Statistical protocol: `docs/PHASE3C_STATISTICAL_PROTOCOL.md`. MIN_SAMPLE=85 (frozen, imported from Phase 3B). Archives: gt-sol-20260930a, gt-sol-20260930b, gt-sol-20260930c, p3a-sol-20261001d2, p3c-sol-20261004e, p3c-sol-20261004f.

## Hypothesis family

| ID | Feature | Rows | Distinct tokens | Min sample | Classification |
|---|---|---|---|---|---|
| H1 | funding_transfer | 147 | 19 | 85 | INSUFFICIENT EVIDENCE |
| H3 | social | 147 | 19 | 85 | INSUFFICIENT EVIDENCE |
| H4 | social | 147 | 19 | 85 | INSUFFICIENT EVIDENCE |
| H8 | news | 140 | 18 | 85 | INSUFFICIENT EVIDENCE |
| H9 | liquidity_event | 266 | 36 | 85 | INSUFFICIENT EVIDENCE |
| H10 | creator_state | 221 | 35 | 85 | INSUFFICIENT EVIDENCE |

## Per-hypothesis detail

### H1

*Reason*: n_tokens=19 (n_rows=147) < MIN_SAMPLE=85; the frozen Phase 3B threshold is not relaxed for Phase 3C

* **y_classified**: n=147, spearman_r=0.1743, raw_p=0.8513, FDR_p=0.8778
  * Per archive: p3a-sol-20261001d2: n_tokens=5, spearman=0.25; p3c-sol-20261004f: n_tokens=14, spearman=0.1448
* **y_direction**: n=147, spearman_r=n/a, raw_p=n/a, FDR_p=n/a
  * Per archive: p3a-sol-20261001d2: n_tokens=5, spearman=n/a; p3c-sol-20261004f: n_tokens=14, spearman=n/a

### H3

*Reason*: n_tokens=19 (n_rows=147) < MIN_SAMPLE=85; the frozen Phase 3B threshold is not relaxed for Phase 3C

* **y_classified**: n=147, spearman_r=n/a, raw_p=n/a, FDR_p=n/a
  * Per archive: p3a-sol-20261001d2: n_tokens=5, spearman=n/a; p3c-sol-20261004f: n_tokens=14, spearman=n/a
* **y_direction**: n=147, spearman_r=n/a, raw_p=n/a, FDR_p=n/a
  * Per archive: p3a-sol-20261001d2: n_tokens=5, spearman=n/a; p3c-sol-20261004f: n_tokens=14, spearman=n/a

### H4

*Reason*: n_tokens=19 (n_rows=147) < MIN_SAMPLE=85; the frozen Phase 3B threshold is not relaxed for Phase 3C

* **y_classified**: n=147, spearman_r=n/a, raw_p=n/a, FDR_p=n/a
  * Per archive: p3a-sol-20261001d2: n_tokens=5, spearman=n/a; p3c-sol-20261004f: n_tokens=14, spearman=n/a
* **y_direction**: n=147, spearman_r=n/a, raw_p=n/a, FDR_p=n/a
  * Per archive: p3a-sol-20261001d2: n_tokens=5, spearman=n/a; p3c-sol-20261004f: n_tokens=14, spearman=n/a

### H8

*Reason*: n_tokens=18 (n_rows=140) < MIN_SAMPLE=85; the frozen Phase 3B threshold is not relaxed for Phase 3C

* **y_classified**: n=140, spearman_r=n/a, raw_p=n/a, FDR_p=n/a
  * Per archive: p3a-sol-20261001d2: n_tokens=4, spearman=n/a; p3c-sol-20261004f: n_tokens=14, spearman=n/a
* **y_direction**: n=140, spearman_r=n/a, raw_p=n/a, FDR_p=n/a
  * Per archive: p3a-sol-20261001d2: n_tokens=4, spearman=n/a; p3c-sol-20261004f: n_tokens=14, spearman=n/a

### H9

*Reason*: n_tokens=36 (n_rows=266) < MIN_SAMPLE=85; the frozen Phase 3B threshold is not relaxed for Phase 3C

* **y_classified**: n=266, spearman_r=n/a, raw_p=n/a, FDR_p=n/a
  * Per archive: gt-sol-20260930a: n_tokens=12, spearman=n/a; gt-sol-20260930c: n_tokens=5, spearman=n/a; p3a-sol-20261001d2: n_tokens=5, spearman=n/a; p3c-sol-20261004f: n_tokens=14, spearman=n/a
* **y_direction**: n=266, spearman_r=n/a, raw_p=n/a, FDR_p=n/a
  * Per archive: gt-sol-20260930a: n_tokens=12, spearman=n/a; gt-sol-20260930c: n_tokens=5, spearman=n/a; p3a-sol-20261001d2: n_tokens=5, spearman=n/a; p3c-sol-20261004f: n_tokens=14, spearman=n/a

### H10

*Reason*: n_tokens=35 (n_rows=221) < MIN_SAMPLE=85; the frozen Phase 3B threshold is not relaxed for Phase 3C

* **y_classified**: n=221, spearman_r=0.384, raw_p=0.004499, FDR_p=0.0135
  * Per archive: gt-sol-20260930a: n_tokens=12, spearman=0.663; gt-sol-20260930c: n_tokens=4, spearman=n/a; p3a-sol-20261001d2: n_tokens=5, spearman=1; p3c-sol-20261004f: n_tokens=14, spearman=0.1913
* **y_direction**: n=221, spearman_r=-0.09028, raw_p=0.8778, FDR_p=0.8778
  * Per archive: gt-sol-20260930a: n_tokens=12, spearman=n/a; gt-sol-20260930c: n_tokens=4, spearman=n/a; p3a-sol-20261001d2: n_tokens=5, spearman=n/a; p3c-sol-20261004f: n_tokens=14, spearman=n/a

## Overall classification

**INSUFFICIENT EVIDENCE**

By classification: {"INSUFFICIENT EVIDENCE": 6}.
