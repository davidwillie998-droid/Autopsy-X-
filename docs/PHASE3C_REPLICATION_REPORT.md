# Phase 3C Replication Report

Dedicated H10 replication audit (Phase 3C instruction 9): the Phase 3B false positive (spearman~=0.65 on 109 rows / 21 tokens) is re-examined collapsing each token to one representative row, controlling for archive identity, and broken down by archive.

H10 classification in this evidence: **INSUFFICIENT EVIDENCE**. n_tokens=35 (n_rows=221) < MIN_SAMPLE=85; the frozen Phase 3B threshold is not relaxed for Phase 3C

Tokens after one-row-per-token collapse: 35.

## y_classified

* Spearman, one row per token: 0.4059
* Partial Spearman controlling for archive identity: 0.4094

| Archive | Rows | Tokens | Spearman | Permutation p |
|---|---|---|---|---|
| gt-sol-20260930a | 46 | 12 | 0.663 | 0.0115 |
| gt-sol-20260930c | 28 | 4 | n/a | n/a |
| p3a-sol-20261001d2 | 35 | 5 | 1 | 0.2079 |
| p3c-sol-20261004f | 112 | 14 | 0.1913 | 0.5351 |

## y_direction

* Spearman, one row per token: -0.1204
* Partial Spearman controlling for archive identity: -0.1169

| Archive | Rows | Tokens | Spearman | Permutation p |
|---|---|---|---|---|
| gt-sol-20260930a | 46 | 12 | n/a | n/a |
| gt-sol-20260930c | 28 | 4 | n/a | n/a |
| p3a-sol-20261001d2 | 35 | 5 | n/a | n/a |
| p3c-sol-20261004f | 112 | 14 | n/a | n/a |

## Conclusion

The relationship does not survive as independent evidence under the pre-registered minimum-sample rule applied to distinct tokens; whether it would survive at a larger n is the open question Phase 3C's expanded archive set tests directly, reported in the hypothesis-family table above.
