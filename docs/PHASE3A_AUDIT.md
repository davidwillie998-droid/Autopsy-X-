# Phase 3A Repository Audit

Baseline: commit `30fe094`, 160 tests passing, Phase 2 verdict VERIFIED WITH LIMITATIONS. Written before any Phase 3A code.

| Component | Current capability | Missing capability | Relevant tests | Phase 3A change required | Look-ahead risk |
|---|---|---|---|---|---|
| Transport (`providers/http.py`) | GET with retries, adaptive rate on 429, circuit breaker, raw bytes + request/response clocks | POST (JSON-RPC); per-attempt status/backoff log, so retries and backoff time are invisible in evidence | `test_transport.py`, transport tests in `test_phase2_replay.py` | add POST through the same retry path; attempt log carried into the manifest | none (transport) |
| Raw archive (`data/raw.py`) | content-addressed bodies, manifest per exchange, errors kept | per-attempt telemetry fields | `test_phase2_adapters.py` | optional `attempt_log` field with a default, so Phase 2 manifests still load | none |
| GeckoTerminal / DexScreener adapters | pools, trades (≤300), OHLCV, token info, pairs | creator state when holder count is null (dropped with the holder snapshot) | `test_phase2_adapters.py` | separate creator-state observation, emitted by a Phase 3A parser so Phase 2 normalization (and its committed dataset hashes) is untouched | low: creator data must stay invisible before its `seen_ts` |
| Solana RPC / funding transfers | none; `FundingTransfer` model exists, only the synthetic generator fills it | RPC adapter, signer vs beneficiary separation, failed-transaction handling, pagination | none | new adapter + transfer observation record | medium: transfers have block time ≠ ingestion time; replay must filter on `seen_ts` |
| Liquidity events | `LiquidityEvent` model + engine consumers; no real producer | add/remove detection from chain data | engine tests (synthetic) | program-agnostic vault-balance event observation from `getTransaction` | high: must never derive history from current state |
| Creator / holder state | `HolderSnapshot` from token info, point-in-time by `seen_ts` | distinction KNOWN / UNKNOWN at assessment / UNAVAILABLE / OBSERVED_LATER | `test_phase2_pit.py` | state classifier in the evidence layer only; regression test that later observations leave earlier assessments unchanged | high: OBSERVED_LATER is a hindsight label and must never enter an assessment |
| News / social | `NewsEvent`, `SocialPost` models; catalyst and attention engines; no provider | acquisition with publication vs observation vs ingestion time | engine tests (synthetic) | keyless acquisition adapters (GDELT, Reddit) with explicit availability states; no sentiment | medium: GDELT gives crawl time, not publication time, which must stay NOT_OBSERVED |
| Freshness / telemetry | Phase 2 evidence: poll intervals, errors, final rate | per-provider latency, status, rate-limit, retry, backoff, freshness age; frozen policy | `test_phase2_evidence.py` | telemetry computed in the evidence layer; freshness policy taken from the existing `data_quality.max_price_age_ms` and fingerprinted | none |
| Universe / multi-day | seeded stratified selection recorded in `selection.json` | frozen universe reused across chained runs (Actions jobs are capped well below a day) | `test_selection_is_seeded_and_recorded` | `universe.json` written before collection and reused on resume | low |
| Replay (`replay.py`) | deterministic, config-pinned, provenance per step, aborts on future observations | none for 3A | `test_phase2_replay.py` | unchanged | already guarded |
| Database (`migrations/`) | 0001 + 0002 verified on PostgreSQL 16 | tables for transfer, liquidity-event, creator-state, news/social observations | DB tests in `test_phase2_replay.py` | migration 0003 | none |
| Evidence / renderers / traceability | Phase 2 evidence, report, status; trace checker | Phase 3A evidence, coverage matrix, readiness gate | `test_phase2_evidence.py` | new `phase3a_verify` reusing the trace checker; the frozen Phase 2 status rendering moves to `docs/PHASE2_SYSTEM_STATUS.md` because `SYSTEM_STATUS.md` becomes the living status | none |
| Configuration / fingerprint | `Config.fingerprint()`, Phase 2 rule fingerprint | readiness thresholds | — | `config/phase3a_readiness.toml` with thresholds unset and `approved = false` until a human sets them | none |

## Constraints found during the audit

* The development container reaches no vendor host; all live acquisition runs on GitHub Actions (`phase2-acquire.yml` pattern).
* GitHub Actions jobs cannot run for days, and scheduled workflows only run on the default branch. A real multi-day collection cannot happen inside this task; the collector can only be prepared for it (frozen universe, resumable chained runs).
* No readiness thresholds exist anywhere in the project. Phase 2's only quantitative data-quality convention is `max_price_age_ms = 120000`.
* Any change to the Phase 2 parsers would change the committed Phase 2 dataset hashes and fail the Phase 2 reproduction test. Phase 3A therefore adds parsers alongside them rather than changing them.
