# Phase 3B Statistical Report

Contract hash `a317239dfc492486657b55f8980c463559de37edef95af21b5247420a4aee527` (`docs/PHASE3B_RESEARCH_CONTRACT.md`, version `3b.1`). Repository commit `617355f874d949431eb93d8ac2d3ecc7b6479aa3`, configuration hash `417bd32cce8fb72c`. Eligible archives: gt-sol-20260930a, gt-sol-20260930b, gt-sol-20260930c, p3a-sol-20261001d2.

## Question

Does any Phase 3A information (funding transfers, chain-derived liquidity events, creator/holder state, news, social) carry reproducible incremental information about a token's move classification beyond the existing Phase 2 engine. This is evidence qualification, not profitability validation.

## Excluded hypotheses (standing freeze, unchanged)

* **H2**: frozen by the standing instruction carried from Phase 2 through Phase 3A: "do not test or claim H2, H5, H6 or H7"; Phase 3B does not lift it
* **H5**: frozen by the standing instruction carried from Phase 2 through Phase 3A: "do not test or claim H2, H5, H6 or H7"; Phase 3B does not lift it
* **H6**: frozen by the standing instruction carried from Phase 2 through Phase 3A: "do not test or claim H2, H5, H6 or H7"; Phase 3B does not lift it
* **H7**: frozen by the standing instruction carried from Phase 2 through Phase 3A: "do not test or claim H2, H5, H6 or H7"; Phase 3B does not lift it

## Hypothesis family

| ID | Feature | Target | Rows joined | Distinct tokens | Min. sample | Classification |
|---|---|---|---|---|---|---|
| H1 | funding_transfer | y_classified/y_direction | 35 | 5 | 85 | **INSUFFICIENT EVIDENCE** |
| H3 | social | y_classified/y_direction | 35 | 5 | 85 | **INSUFFICIENT EVIDENCE** |
| H4 | social | y_classified/y_direction | 35 | 5 | 85 | **INSUFFICIENT EVIDENCE** |
| H8 | news | y_classified/y_direction | 28 | 4 | 85 | **INSUFFICIENT EVIDENCE** |
| H9 | liquidity_event | y_classified/y_direction | 154 | 22 | 85 | **INSUFFICIENT EVIDENCE** |
| H10 | creator_state | y_classified/y_direction | 109 | 21 | 85 | **INSUFFICIENT EVIDENCE** |

## Per-hypothesis detail

### H1

*Reason*: n_tokens=5 (n_rows=35 before collapsing non-independent within-token repeats) < MIN_SAMPLE=85 (80% power to detect r>=0.3); statistics above are exploratory and non-confirmatory per the contract's pre-registered gate

* **y_classified**: n_rows=35, pearson_r=0.25, spearman_r=0.25, raw_p=1, FDR-corrected_p=1
* **y_direction**: n_rows=35, pearson_r=n/a, spearman_r=n/a, raw_p=n/a, FDR-corrected_p=n/a

### H3

*Reason*: n_tokens=5 (n_rows=35 before collapsing non-independent within-token repeats) < MIN_SAMPLE=85 (80% power to detect r>=0.3); statistics above are exploratory and non-confirmatory per the contract's pre-registered gate

* **y_classified**: n_rows=35, pearson_r=n/a, spearman_r=n/a, raw_p=n/a, FDR-corrected_p=n/a
* **y_direction**: n_rows=35, pearson_r=n/a, spearman_r=n/a, raw_p=n/a, FDR-corrected_p=n/a

### H4

*Reason*: n_tokens=5 (n_rows=35 before collapsing non-independent within-token repeats) < MIN_SAMPLE=85 (80% power to detect r>=0.3); statistics above are exploratory and non-confirmatory per the contract's pre-registered gate

* **y_classified**: n_rows=35, pearson_r=n/a, spearman_r=n/a, raw_p=n/a, FDR-corrected_p=n/a
* **y_direction**: n_rows=35, pearson_r=n/a, spearman_r=n/a, raw_p=n/a, FDR-corrected_p=n/a

### H8

*Reason*: n_tokens=4 (n_rows=28 before collapsing non-independent within-token repeats) < MIN_SAMPLE=85 (80% power to detect r>=0.3); statistics above are exploratory and non-confirmatory per the contract's pre-registered gate

* **y_classified**: n_rows=28, pearson_r=n/a, spearman_r=n/a, raw_p=n/a, FDR-corrected_p=n/a
* **y_direction**: n_rows=28, pearson_r=n/a, spearman_r=n/a, raw_p=n/a, FDR-corrected_p=n/a

### H9

*Reason*: n_tokens=22 (n_rows=154 before collapsing non-independent within-token repeats) < MIN_SAMPLE=85 (80% power to detect r>=0.3); statistics above are exploratory and non-confirmatory per the contract's pre-registered gate

* **y_classified**: n_rows=154, pearson_r=n/a, spearman_r=n/a, raw_p=n/a, FDR-corrected_p=n/a
* **y_direction**: n_rows=154, pearson_r=n/a, spearman_r=n/a, raw_p=n/a, FDR-corrected_p=n/a

### H10

*Reason*: n_tokens=21 (n_rows=109 before collapsing non-independent within-token repeats) < MIN_SAMPLE=85 (80% power to detect r>=0.3); statistics above are exploratory and non-confirmatory per the contract's pre-registered gate

* **y_classified**: n_rows=109, pearson_r=0.4737, spearman_r=0.6526, raw_p=0.0002499, FDR-corrected_p=0.0007498, winsorized_spearman=0.6634, early/late spearman=0.594/0.7229, partial_spearman(controlling step_index)=0.6563
* **y_direction**: n_rows=109, pearson_r=-0.0688, spearman_r=-0.09736, raw_p=0.938, FDR-corrected_p=1, winsorized_spearman=n/a, early/late spearman=-0.1196/-0.07418, partial_spearman(controlling step_index)=-0.05882

## Strongest candidate

**H10**, |spearman_r|=0.653 on 109 joined rows. Still classified **INSUFFICIENT EVIDENCE**: the row count overstates independence (see the false positive below); the number of distinct tokens behind it falls short of MIN_SAMPLE.

## Strongest false positive, and why it was rejected

**H10, target `y_classified`.** Raw Spearman correlation 0.653 over 109 joined rows, block-permutation p=0.00025, Benjamini-Hochberg-corrected p=0.00075 -- a result that would read as a clear, FDR-surviving finding if the 109 rows were treated as independent observations. They are not: a token's creator-held percentage does not change from one 5-minute replay step to the next, and a token's classifiability moves slowly too, so the HORIZON_STEPS forward join repeats essentially the same (feature, outcome) pair 5-7 times per token. The 109 rows come from only 21 distinct tokens. Applying the contract's minimum-sample rule to that real degrees-of-freedom count (not the row count) puts every hypothesis, including this one, far below MIN_SAMPLE=85. An adversarial check for a second, independent confound (association with the predictor's own step index, as a proxy for elapsed-time/data-coverage effects) did not explain the correlation on its own (partial Spearman barely moved from the raw value); the overlapping-observations problem alone is sufficient to reject it. This is reported, not discarded, because Step 16 of the contract requires exactly this adversarial accounting before any statistic is trusted.

## Overall classification

**INSUFFICIENT EVIDENCE** -- NO REPRODUCIBLE INCREMENTAL INFORMATION ESTABLISHED

By classification: {"INSUFFICIENT EVIDENCE": 6}.

## Economic significance

No hypothesis cleared the minimum-sample gate, so no effect size, turnover, transaction-cost, or slippage analysis is performed: there is nothing economically significant to evaluate yet, which is distinct from there being evidence of no effect.

## Limitations

* The entire evaluable Phase 3A/2 dataset spans 22 distinct tokens across 3 replayable archives (A, C, D2); archive B is not replayable (no live-poll window) and contributes no assessments.
* Phase 3A observation-layer data (funding transfers, social, news) exists only where an archive's acquisition plan requested it; for A and C that is nothing, so H1/H3/H4/H8's usable sample comes from D2 alone (4-5 tokens).
* The production engine's own funding/social/news/creator-pct features remain unavailable in every archive (`data.normalize.PHASE2_CAPABILITIES`, frozen since Phase 2): H1, H3, H4, H9 and H10's baseline engine fields report feature_status OK in 0% of assessments, so no engine-feature baseline exists to compare the candidate features against; only the observation-layer-vs-outcome test could run at all.
* H9's candidate feature (any observed liquidity_event) is nearly constant (observed for almost every token from pool-creation metadata alone), giving zero variance and an undefined correlation; the chain-derived vault-delta liquidity signal specifically is rarer still.
* H9's text ("cross-venue confirmation") is about multi-venue price agreement, which Phase 3A does not add; its candidate feature (liquidity_event presence) is a loose proxy chosen when the contract was frozen, not a close match to the hypothesis as originally worded in Phase 2. This mapping is recorded here rather than corrected, because the contract was already frozen before any result was computed.
* No hypothesis reached MIN_SAMPLE, so robustness, temporal-stability and economic-significance analysis did not run in a confirmatory capacity for any of them; the diagnostic numbers shown for H10 illustrate what an (invalid) row-level analysis would have shown, not a finding.

## What this does not establish

This report does not establish that Phase 3A information is useless, only that the current archives do not contain enough independent token-level observations to tell. A null result from an underpowered sample is not evidence of no effect; it is an absence of evidence, reported as such.
