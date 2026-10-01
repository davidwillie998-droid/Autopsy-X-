# Phase 3A Report: Data-Coverage Hardening

Generated from `artifacts/phase3a/PHASE3A_EVIDENCE.json` by `intel/autopsyx/research/phase3a_verify.py`. Every number below is a value in that file; the renderer computes nothing.

## PHASE 3A STATUS

* Commit: `32624c0f5265aaed751bcc11c2c84497593d6364`
* Branch: `ccr-dea9382c-vwhvi6`
* Working tree: clean for intel/autopsyx, intel/config, intel/migrations
* Tests: Passed 265, Failed 0, Skipped 0
* Provider error rate: 11.4% (78 of 687 requests)
* Freshness compliance: 0.8% (501 governed evaluations, 497 stale)
* Funding coverage: 0 of 25 archive-token rows OBSERVED (0.0%)
* Liquidity coverage: 25 of 25 archive-token rows OBSERVED (100.0%); chain-derived add/remove in 0 rows (0.0%), the rest is provider pool-creation metadata only
* Creator-state coverage: 20 of 25 archive-token rows OBSERVED (80.0%)
* Holder-state coverage: 16 of 25 archive-token rows OBSERVED (64.0%)
* News coverage: 0 of 25 archive-token rows OBSERVED (0.0%)
* Social coverage: 0 of 25 archive-token rows OBSERVED (0.0%)
* Multi-day collection: NOT PERFORMED (longest span on one universe 0.035594 days)
* Universe size: 25 distinct tokens over 3 archives
* Replay determinism: VERIFIED
* Look-ahead: NONE DETECTED
* Traceability: VERIFIED
* Evidence integrity: VERIFIED
* Finalization gate: BLOCKED
* Readiness: NOT_READY

## Readiness gate

Result: **NOT_READY**. Rule: READY only if every integrity condition holds, the readiness config is approved by a named human, every threshold is set, and every metric meets its threshold; otherwise NOT_READY with one reason per failure.

Reasons:

* thresholds not approved by a human (config/phase3a_readiness.toml: approved = false)
* threshold funding_transfer_min_share is UNSET (metric funding_transfer_share = 0.0)
* threshold liquidity_vault_delta_min_share is UNSET (metric liquidity_vault_delta_share = 0.0)
* threshold creator_state_min_share is UNSET (metric creator_state_share = 0.8)
* threshold holder_state_min_share is UNSET (metric holder_state_share = 0.64)
* threshold news_min_share is UNSET (metric news_share = 0.0)
* threshold social_min_share is UNSET (metric social_share = 0.0)
* threshold freshness_min_compliance is UNSET (metric freshness_compliance = 0.007984)
* threshold provider_max_error_rate is UNSET (metric provider_error_rate = 0.113537)
* threshold multi_day_min_days is UNSET (metric multi_day_days = 0.035594)
* threshold universe_min_tokens is UNSET (metric universe_tokens = 25)

Hypothesis testing does not start: the gate is not READY.

## Finalization gate

Result: **BLOCKED**. Phase 3B: NOT STARTED.

| Check | Result |
|---|---|
| archive_d_acquisition_complete | FAIL |
| archive_d_included_and_provenance_verified | FAIL |
| cross_seed_identical | pass |
| every_included_archive_provenance_verified | pass |
| existing_phase2_checks_passed | pass |
| lookahead_a_to_f_passed | pass |
| phase3a_integrity | pass |
| scope_clean | pass |
| tests_green | pass |
| traceability | pass |

## Archive provenance and inclusion

Rule: an archive enters the evidence only if data.provenance.verify() returns verified: its runner dataset hash is recorded and equals, exactly, the hash rebuilt twice from the committed raw archive (and, where the runner sealed canonical files, the hash of those committed files), and a sealed archive's acquisition reports COMPLETE; any other archive is listed as excluded with the verification result.

| Archive | Status | Runner hash source | Hash scope | Runner phase2 hash | Rebuilt phase2 hash | Runner phase3a hash | Rebuilt phase3a hash | Rebuild twice identical | Committed canonical = runner | Verified |
|---|---|---|---|---|---|---|---|---|---|---|
| gt-sol-20260930a | included | normalize_stdout.json (Phase 2 runner normalization) | phase2_records only (archive predates Phase 3A runner sealing) | fb7d3607fbd91c34df16fad4b77ce27119a369b6fc5740f94d45dbeb186b2d42 | fb7d3607fbd91c34df16fad4b77ce27119a369b6fc5740f94d45dbeb186b2d42 | not recorded | ad59f1cd7eea33df1b8fba9d5b58305826ad9b5087a55f351c9a4fbe4cdae35a | yes | n/a | yes |
| gt-sol-20260930b | included | normalize_stdout.json (Phase 2 runner normalization) | phase2_records only (archive predates Phase 3A runner sealing) | 031917e87897293846524c7f2977134f0e723a65d3220cf98f175eb8f15d9f36 | 031917e87897293846524c7f2977134f0e723a65d3220cf98f175eb8f15d9f36 | not recorded | 0687e2b8bd58addb879fc33cb6518b3495127f74e4c3a16290b5bd7dafa68206 | yes | n/a | yes |
| gt-sol-20260930c | included | normalize_stdout.json (Phase 2 runner normalization) | phase2_records only (archive predates Phase 3A runner sealing) | 1ebe77ec9ec2e9b6f06da26cbcce17721db4504f6029baf610931f5489e71d14 | 1ebe77ec9ec2e9b6f06da26cbcce17721db4504f6029baf610931f5489e71d14 | not recorded | 35e114f1d5ee5f6b2f067df76f9329ff3b7d644f3470d15e2bb7b7b7dfbfeefd | yes | n/a | yes |
| p3a-sol-20261001d | AUDIT / REFERENCE ONLY — PROVENANCE HASH UNAVAILABLE | none | no runner dataset hash recorded | none | e085fa92672800cb3f74e0a5a2b624e81312886099dfc742a3376a65ff4bdc42 | none | 9f24fd4bb2a23971ce17ed9497c04ca72740f1ac72c4ec742a49d96191462c74 | yes | n/a | NO |

## Per-archive funnel

Definitions are the Phase 2 funnel's, unchanged. An archive without a replay has evaluable and classified not measured; they are not counted as failures.

| Archive | Step | Numerator | Denominator | Share | Denominator definition | Not measured |
|---|---|---|---|---|---|---|
| gt-sol-20260930a | discovered -> attempted | 12 | 93 | 12.9% | distinct tokens described by any discovery or poll response |  |
| gt-sol-20260930a | attempted -> successful | 12 | 12 | 100.0% | tokens picked by the seeded stratified selection and polled |  |
| gt-sol-20260930a | successful -> evaluable | 12 | 12 | 100.0% | attempted tokens with at least one successful OHLCV and one successful trades response |  |
| gt-sol-20260930a | evaluable -> classified | 3 | 12 | 25.0% | tokens with at least one replay assessment whose price input was OK and not NO_DATA |  |
| gt-sol-20260930b | discovered -> attempted | 8 | 90 | 8.9% | distinct tokens described by any discovery or poll response |  |
| gt-sol-20260930b | attempted -> successful | 0 | 8 | 0.0% | tokens picked by the seeded stratified selection and polled |  |
| gt-sol-20260930b | successful -> evaluable | n/a | 0 | n/a | attempted tokens with at least one successful OHLCV and one successful trades response | archive not replayable: no replay assessment exists, so evaluable and classified are not measured |
| gt-sol-20260930b | evaluable -> classified | n/a | n/a | n/a | tokens with at least one replay assessment whose price input was OK and not NO_DATA | archive not replayable: no replay assessment exists, so evaluable and classified are not measured |
| gt-sol-20260930c | discovered -> attempted | 5 | 93 | 5.4% | distinct tokens described by any discovery or poll response |  |
| gt-sol-20260930c | attempted -> successful | 5 | 5 | 100.0% | tokens picked by the seeded stratified selection and polled |  |
| gt-sol-20260930c | successful -> evaluable | 5 | 5 | 100.0% | attempted tokens with at least one successful OHLCV and one successful trades response |  |
| gt-sol-20260930c | evaluable -> classified | 2 | 5 | 40.0% | tokens with at least one replay assessment whose price input was OK and not NO_DATA |  |

## Baseline (A, B, C) versus A, B, C, D

Baseline: Phase 3A evidence at commit `8df2918` over gt-sol-20260930a, gt-sol-20260930b, gt-sol-20260930c. Added: none.

Classification of the change: **SAMPLE EXPANSION** (A, B, C recomputed now reproduce the committed baseline: yes). differences are descriptive; Phase 3A defines no statistical test, so no difference is called an improvement, and none implies predictive power or edge.

| Sample | A, B, C | A, B, C, D |
|---|---|---|
| archives | 3 | 3 |
| attempted | 25 | 25 |
| classified | 5 | 5 |
| coverage_rows | 25 | 25 |
| discovered | 276 | 276 |
| evaluable | 17 | 17 |
| successful | 17 | 17 |

| Metric | Baseline committed | A, B, C now | A, B, C, D | Difference (descriptive) | A, B, C reproduces |
|---|---|---|---|---|---|
| provider_error_rate | 0.113537 | 0.113537 | 0.113537 | 0.0 | yes |
| freshness_compliance | 0.007984 | 0.007984 | 0.007984 | 0.0 | yes |
| universe_tokens | 25 | 25 | 25 | 0 | yes |
| coverage_rows | 25 | 25 | 25 | 0 | yes |
| liquidity_vault_delta_share | 0.0 | 0.0 | 0.0 | 0.0 | yes |
| coverage_share.funding_transfer | 0.0 | 0.0 | 0.0 | 0.0 | yes |
| coverage_share.liquidity_events | 1.0 | 1.0 | 1.0 | 0.0 | yes |
| coverage_share.creator_state | 0.8 | 0.8 | 0.8 | 0.0 | yes |
| coverage_share.holder_state | 0.64 | 0.64 | 0.64 | 0.0 | yes |
| coverage_share.news | 0.0 | 0.0 | 0.0 | 0.0 | yes |
| coverage_share.social | 0.0 | 0.0 | 0.0 | 0.0 | yes |
| coverage_share.ohlcv | 0.84 | 0.84 | 0.84 | 0.0 | yes |
| coverage_share.trades | 0.68 | 0.68 | 0.68 | 0.0 | yes |
| coverage_share.freshness | 0.0 | 0.0 | 0.0 | 0.0 | yes |
| coverage_share.provider | 0.36 | 0.36 | 0.36 | 0.0 | yes |
| coverage_share.replayability | 0.68 | 0.68 | 0.68 | 0.0 | yes |
| coverage_share.point_in_time_validity | 1.0 | 1.0 | 1.0 | 0.0 | yes |

| Archive | Look-ahead A-F | Two replays |
|---|---|---|
| gt-sol-20260930a | passed | identical |
| gt-sol-20260930b | n/a | n/a |
| gt-sol-20260930c | passed | identical |

| Integrity | Baseline | Now |
|---|---|---|
| contract_valid | pass | pass |
| evidence_integrity | pass | pass |
| freshness_policy_frozen | pass | pass |
| no_blank_cells | pass | pass |
| point_in_time_validity | pass | pass |
| replay_determinism | pass | pass |
| scope_clean | pass | pass |
| tests_green | pass | pass |
| traceability | pass | pass |

## Existing Phase 2 checks at this commit

| Archive | Clock / hash violations | Bodies missing | Journal | PostgreSQL (Phase 2 load) | Result |
|---|---|---|---|---|---|
| gt-sol-20260930a | hash_mismatch 0, length_mismatch 0, missing_body_file 0, missing_request_ts 0, missing_response_ts 0, out_of_order_response 0, response_before_request 0 | 0 | 120 entries, 0 breaks, 0 mismatches | all checks zero | pass |
| gt-sol-20260930b | hash_mismatch 0, length_mismatch 0, missing_body_file 0, missing_request_ts 0, missing_response_ts 0, out_of_order_response 0, response_before_request 0 | 0 | n/a | not run: archive not replayable (no journal to load) | pass |
| gt-sol-20260930c | hash_mismatch 0, length_mismatch 0, missing_body_file 0, missing_request_ts 0, missing_response_ts 0, out_of_order_response 0, response_before_request 0 | 0 | 50 entries, 0 breaks, 0 mismatches | all checks zero | pass |

## Coverage matrix totals

25 rows (archive x token), 0 blank cells. Full matrix: `artifacts/phase3a/PHASE3A_COVERAGE.json` (sha256 `db0828e6f4156841742db776d7b3611c24ebfbbab29daf6d2724521fad71ccff`).

State rule: OBSERVED if any OBSERVED record; else NOT_OBSERVED if any; else NOT_APPLICABLE if the question was not applicable; else ERROR if any; else UNKNOWN if the archive's plan included the source but this token was never asked; else UNAVAILABLE (source not in the archive's acquisition plan).

| Dimension | Positive state | Share | Rows by state |
|---|---|---|---|
| creator_state | OBSERVED | 80.0% | NOT_OBSERVED 1, OBSERVED 20, UNKNOWN 4 |
| freshness | OBSERVED | 0.0% | NOT_OBSERVED 8, STALE 17 |
| funding_transfer | OBSERVED | 0.0% | UNAVAILABLE 25 |
| holder_state | OBSERVED | 64.0% | NOT_OBSERVED 5, OBSERVED 16, UNKNOWN 4 |
| liquidity_events | OBSERVED | 100.0% | OBSERVED 25 |
| news | OBSERVED | 0.0% | UNAVAILABLE 25 |
| ohlcv | OBSERVED | 84.0% | OBSERVED 21, UNKNOWN 4 |
| point_in_time_validity | VERIFIED | 100.0% | VERIFIED 25 |
| provider | OBSERVED | 36.0% | ERROR 12, NOT_OBSERVED 4, OBSERVED 9 |
| replayability | VERIFIED | 68.0% | NOT_REPLAYABLE 8, VERIFIED 17 |
| social | OBSERVED | 0.0% | UNAVAILABLE 25 |
| trades | OBSERVED | 68.0% | OBSERVED 17, UNKNOWN 8 |

## Archives

| Archive | Family | Run | Universe | Tokens | Exchanges | Observations | Replayable | Two replays | Look-ahead audit | PostgreSQL |
|---|---|---|---|---|---|---|---|---|---|---|
| gt-sol-20260930a | phase2 | COMPLETE | selection.json | 12 | 449 | 184 | yes | identical | passed | LOADED |
| gt-sol-20260930b | phase2 | not recorded | selection.json | 8 | 13 | 105 | no | n/a | n/a | LOADED |
| gt-sol-20260930c | phase2 | COMPLETE | selection.json | 5 | 225 | 141 | yes | identical | passed | LOADED |

## Provider telemetry

| Archive | Provider | Requests | Errors | Error rate | Retries before success | Rate-limited attempts | Backoff s | Latency p50 ms | Latency p95 ms | Failures without attempt log |
|---|---|---|---|---|---|---|---|---|---|---|
| gt-sol-20260930a | dexscreener | 15 | 0 | 0.0% | 0 | 0 | 0 | 165 | 205 | 0 |
| gt-sol-20260930a | geckoterminal | 434 | 78 | 18.0% | 606 | 0 | 0 | 258 | 1130 | 78 |
| gt-sol-20260930b | geckoterminal | 13 | 0 | 0.0% | 2 | 0 | 0 | 88 | 773 | 0 |
| gt-sol-20260930c | dexscreener | 16 | 0 | 0.0% | 0 | 0 | 0 | 185 | 226 | 0 |
| gt-sol-20260930c | geckoterminal | 209 | 0 | 0.0% | 21 | 0 | 0 | 244 | 1092 | 0 |

## Freshness

Policy fingerprint `58fe8ee8476b824fde285065d8dafbebb594f9bf1cd0df04091823d13b9881ff`, frozen: yes. Threshold 120000 ms from config/default.toml [data_quality] max_price_age_ms, governing gt.pools_multi, ds.pairs, gt.trades, gt.ohlcv.

| Archive | Endpoint | Evaluations | Age p50 ms | Age max ms | Stale | Compliance |
|---|---|---|---|---|---|---|
| gt-sol-20260930a | ds.pairs | 14 | 225964 | 265310 | 12 | 14.3% |
| gt-sol-20260930a | gt.new_pools | 2 | 2021 | 2021 | n/a | NOT_APPLICABLE |
| gt-sol-20260930a | gt.ohlcv | 144 | 222742 | 301107 | 144 | 0.0% |
| gt-sol-20260930a | gt.pools_multi | 12 | 226214 | 265210 | 12 | 0.0% |
| gt-sol-20260930a | gt.token_info | 14 | 1300961 | 1355639 | n/a | NOT_APPLICABLE |
| gt-sol-20260930a | gt.trades | 144 | 222588 | 300662 | 144 | 0.0% |
| gt-sol-20260930b | gt.new_pools | 2 | 4870 | 4870 | n/a | NOT_APPLICABLE |
| gt-sol-20260930c | ds.pairs | 15 | 172041 | 193056 | 15 | 0.0% |
| gt-sol-20260930c | gt.new_pools | 2 | 4740 | 4740 | n/a | NOT_APPLICABLE |
| gt-sol-20260930c | gt.ohlcv | 82 | 172213 | 228834 | 80 | 2.4% |
| gt-sol-20260930c | gt.pools_multi | 15 | 171973 | 192995 | 15 | 0.0% |
| gt-sol-20260930c | gt.token_info | 16 | 861935 | 873346 | n/a | NOT_APPLICABLE |
| gt-sol-20260930c | gt.trades | 75 | 170234 | 201221 | 75 | 0.0% |

## Creator and holder state at assessment

States come from a point-in-time view only. OBSERVED_LATER is a hindsight label computed afterwards from the full archive; it never enters an assessment.

| Archive | Kind at time | Assessment | Hindsight label |
|---|---|---|---|
| gt-sol-20260930a | creator_state@first | UNKNOWN_AT_ASSESSMENT 12 | OBSERVED_LATER 12 |
| gt-sol-20260930a | creator_state@last | KNOWN_AT_ASSESSMENT 12 | KNOWN_AT_ASSESSMENT 12 |
| gt-sol-20260930a | holder_state@first | UNKNOWN_AT_ASSESSMENT 12 | OBSERVED_LATER 11, UNKNOWN_AT_ASSESSMENT 1 |
| gt-sol-20260930a | holder_state@last | KNOWN_AT_ASSESSMENT 11, UNAVAILABLE_FROM_PROVIDER 1 | KNOWN_AT_ASSESSMENT 11, UNAVAILABLE_FROM_PROVIDER 1 |
| gt-sol-20260930b | creator_state@first | UNKNOWN_AT_ASSESSMENT 8 | OBSERVED_LATER 4, UNKNOWN_AT_ASSESSMENT 4 |
| gt-sol-20260930b | creator_state@last | KNOWN_AT_ASSESSMENT 4, UNKNOWN_AT_ASSESSMENT 4 | KNOWN_AT_ASSESSMENT 4, UNKNOWN_AT_ASSESSMENT 4 |
| gt-sol-20260930b | holder_state@first | UNKNOWN_AT_ASSESSMENT 8 | OBSERVED_LATER 1, UNKNOWN_AT_ASSESSMENT 7 |
| gt-sol-20260930b | holder_state@last | KNOWN_AT_ASSESSMENT 1, UNAVAILABLE_FROM_PROVIDER 3, UNKNOWN_AT_ASSESSMENT 4 | KNOWN_AT_ASSESSMENT 1, UNAVAILABLE_FROM_PROVIDER 3, UNKNOWN_AT_ASSESSMENT 4 |
| gt-sol-20260930c | creator_state@first | KNOWN_AT_ASSESSMENT 4, UNAVAILABLE_FROM_PROVIDER 1 | KNOWN_AT_ASSESSMENT 4, UNAVAILABLE_FROM_PROVIDER 1 |
| gt-sol-20260930c | creator_state@last | KNOWN_AT_ASSESSMENT 4, UNAVAILABLE_FROM_PROVIDER 1 | KNOWN_AT_ASSESSMENT 4, UNAVAILABLE_FROM_PROVIDER 1 |
| gt-sol-20260930c | holder_state@first | KNOWN_AT_ASSESSMENT 3, UNAVAILABLE_FROM_PROVIDER 2 | KNOWN_AT_ASSESSMENT 3, OBSERVED_LATER 1, UNAVAILABLE_FROM_PROVIDER 1 |
| gt-sol-20260930c | holder_state@last | KNOWN_AT_ASSESSMENT 4, UNAVAILABLE_FROM_PROVIDER 1 | KNOWN_AT_ASSESSMENT 4, UNAVAILABLE_FROM_PROVIDER 1 |

## Multi-day collection

Definition: performed = some frozen universe was collected by more than one chained run across more than one UTC date.

| Universe | Archives | Span days | UTC dates |
|---|---|---|---|
| selection:gt-sol | gt-sol-20260930a | 0.035594 | 2026-09-30 |
| selection:gt-sol | gt-sol-20260930b | 0.001762 | 2026-09-30 |
| selection:gt-sol | gt-sol-20260930c | 0.035161 | 2026-09-30 |

## Scope audit

* Engine paths changed since Phase 2: (no changes)
* Unexplained engine changes: 0
* Configuration lines removed: 0
* Forbidden terms present: none
* Phase 2 classification rule identical to frozen: yes
* Hypothesis definitions unchanged: yes; docs/research/14-research-hypotheses.md (no changes)
* Hypotheses tested in Phase 3A: none; not tested or claimed: H2, H5, H6, H7
* Strategy logic added: no

Existing test files changed since Phase 2:

* `intel/tests/test_phase2_evidence.py`: the frozen Phase 2 status rendering now lives in docs/PHASE2_SYSTEM_STATUS.md because docs/SYSTEM_STATUS.md is the living Phase 3A status; same assertion, new path
* `intel/tests/test_phase2_replay.py`: schema version check expects one row per migration file instead of the literal 2, since migration 0003 exists
* `intel/tests/test_transport.py`: two tests added (POST, attempt log); none changed

## Determinism and traceability

* Observations and coverage matrix recomputed in fresh processes under hash seeds 1, 2: identical
* Untraceable numbers in the documents: 0

## Remaining limitations

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

## Next permitted phase

None. The readiness gate is NOT_READY, so Phase 3B (hypothesis testing) does not start. The next permitted work is more Phase 3A data collection and a human decision on the thresholds in config/phase3a_readiness.toml.
