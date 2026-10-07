# Phase 3D Independent Validation Protocol

Status: FROZEN FOR VALIDATION SETUP
Parent: Phase 3C.1 commit 796426ef21181612e763b12d272b542024e08706

## Purpose

Phase 3D independently validates the strongest Phase 3C candidate signal without promoting it to production.

Phase 3C produced INSUFFICIENT EVIDENCE for all six hypotheses because the frozen minimum of 85 distinct tokens was not reached. H10 (creator_state) is the only candidate with a non-null pooled classified-target association, but its apparent effect is unstable across archives and therefore is not treated as established.

Phase 3D is designed to answer one question:

> Does the pre-registered H10 relationship replicate on a genuinely new, contamination-free acquisition set with at least 85 distinct tokens and a chronological out-of-sample evaluation?

## Frozen hypothesis

H10 only.

Feature: creator_state / creator_pct.

Target: the existing Phase 3B classified target.

Horizon: 3 replay steps (15 minutes), unchanged.

No new feature engineering, target engineering, threshold tuning, or hypothesis substitution is permitted after acquisition begins.

## Evidence boundary

The Phase 3C evidence set is not used as validation observations.

The following Phase 3C archives are excluded from the Phase 3D validation sample:

- gt-sol-20260930a
- gt-sol-20260930b
- gt-sol-20260930c
- p3a-sol-20261001d2
- p3c-sol-20261004e
- p3c-sol-20261004f

The two-token overlap between Phase 3C E and F is therefore irrelevant to the Phase 3D validation set, but remains documented as a Phase 3C contamination finding.

## Sample gate

Required minimum: 85 distinct tokens.

The threshold is inherited from the frozen Phase 3B contract and is not relaxed.

Rows do not substitute for distinct-token count.

If fewer than 85 distinct eligible tokens are obtained, Phase 3D remains INSUFFICIENT EVIDENCE and no confirmatory claim is made.

## Acquisition

At least two independent acquisition windows are required.

Each archive must have:

- a unique run id
- a unique acquisition window
- independent universe selection
- complete acquisition status
- verified provenance
- a live replay window
- no token overlap with another Phase 3D archive
- no token overlap with the excluded Phase 3C validation set

Archives are acquired sequentially.

## Statistical procedure

Use the frozen Phase 3B statistical machinery without modification:

- Spearman association
- block permutation
- multiple-testing correction is retained for audit consistency
- adversarial step-index check
- temporal stability check
- chronological walk-forward split when the 85-token gate is met

No model is selected from the validation result.

## Out-of-sample rule

Tokens, not rows, define the split.

The chronologically later half of distinct tokens is the OOS set.

A token belongs wholly to either in-sample or OOS.

No OOS information may influence feature construction, normalization, target definition, or any parameter selection.

## Confirmation rule

H10 may be classified as VALIDATED only if all of the following hold:

1. at least 85 distinct eligible tokens;
2. every contributing archive passes completion and provenance checks;
3. Phase 3D archives are mutually contamination-free;
4. no Phase 3C validation token is reused;
5. the pre-registered association survives the frozen statistical test;
6. the effect remains directionally consistent in chronological OOS evaluation;
7. adversarial step-index checks do not explain the effect;
8. the result is not dependent on a single archive.

Otherwise the result is INSUFFICIENT EVIDENCE or FAILED VALIDATION, as appropriate.

## Production boundary

Phase 3D contains no order placement, wallet signing, strategy execution, EA integration, or live trading.

A successful Phase 3D result does not authorize production deployment. Production integration remains a separate gated decision.
