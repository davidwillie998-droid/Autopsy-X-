# System Status

Living status of the AUTOPSY X intelligence system, generated from `artifacts/phase3a/PHASE3A_EVIDENCE.json`. The frozen Phase 2 status is in `docs/PHASE2_SYSTEM_STATUS.md`.

## Current phase: 3A (data-coverage hardening)

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

## Readiness reasons

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

## What runs

* Acquisition (read-only, keyless): GeckoTerminal, DexScreener, public Solana RPC, GDELT, Reddit.
* Observation contract with explicit availability states; Phase 2 records unchanged.
* Deterministic point-in-time replay; PostgreSQL schema through the latest migration.
* No order placement, no wallets, no strategy logic, no hypothesis testing.

## Limitations

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
