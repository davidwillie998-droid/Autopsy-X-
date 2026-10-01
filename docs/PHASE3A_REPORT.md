# Phase 3A Report: Data-Coverage Hardening

Generated from `artifacts/phase3a/PHASE3A_EVIDENCE.json` by `intel/autopsyx/research/phase3a_verify.py`. Every number below is a value in that file; the renderer computes nothing.

## PHASE 3A STATUS

* Commit: `cc21316e258380f300b113f079d2e61d8272c1ed`
* Branch: `ccr-dea9382c-vwhvi6`
* Working tree: clean for intel/autopsyx, intel/config, intel/migrations
* Tests: Passed 254, Failed 0, Skipped 0
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
