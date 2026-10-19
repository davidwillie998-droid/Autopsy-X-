"""Read-only Phase 3C acquisition diagnostics.

This module does not change normalization, acquisition, readiness thresholds,
or the frozen Phase 2/3A/3B contracts. It measures what the raw archive can
actually support and reports missingness explicitly. UNKNOWN is not treated
as zero or as a pass.
"""
from __future__ import annotations

import argparse
import json
import math
from collections import Counter, defaultdict
from pathlib import Path

from ..data.normalize import normalize as normalize_all
from ..data.providers import geckoterminal as gt
from ..data.raw import RawStore
from . import phase3a_coverage


MINUTE_MS = 60_000


def summarize_timestamps(timestamps: list[int], *, created_ts: int | None = None,
                         interval_ms: int = MINUTE_MS) -> dict:
    """Describe unique bar timestamps without filling gaps or assuming liquidity."""
    if interval_ms <= 0:
        raise ValueError("interval_ms must be positive")
    counts = Counter(int(ts) for ts in timestamps)
    unique = sorted(counts)
    duplicates = sum(n - 1 for n in counts.values())
    if not unique:
        return {
            "observed_rows": len(timestamps), "unique_bars": 0, "duplicate_rows": duplicates,
            "first_bar_ms": None, "last_bar_ms": None, "observed_span_intervals": 0,
            "nonempty_bar_slots_without_observation": None, "bar_density_inside_observed_span": None,
            "longest_consecutive_nonempty_bar_run": 0, "longest_gap_between_nonempty_bars_minutes": 0,
            "misaligned_timestamps": 0, "created_to_last_expected_intervals": None,
            "observed_bars_since_creation": 0, "nonempty_bar_slots_without_observation_since_creation": None,
        }

    expected_span = ((unique[-1] - unique[0]) // interval_ms) + 1
    misaligned_timestamps = sum(ts % interval_ms != 0 for ts in unique)
    missing_inside = max(0, expected_span - len(unique))
    longest_run = 1
    run = 1
    longest_gap = 0
    for left, right in zip(unique, unique[1:]):
        delta = right - left
        steps = max(1, round(delta / interval_ms))
        if delta == interval_ms:
            run += 1
            longest_run = max(longest_run, run)
        else:
            run = 1
            longest_gap = max(longest_gap, steps - 1)

    created_expected = None
    missing_since_creation = None
    if created_ts is not None and created_ts <= unique[-1]:
        # Expected minute slots from the first minute at/after pool creation to
        # the last observed bar. Creation time is a bound, not proof of trading.
        first_expected = ((created_ts + interval_ms - 1) // interval_ms) * interval_ms
        created_expected = max(0, ((unique[-1] - first_expected) // interval_ms) + 1)
        observed_after_creation = sum(first_expected <= ts <= unique[-1] for ts in unique)
        missing_since_creation = max(0, created_expected - observed_after_creation)

    return {
        "observed_rows": len(timestamps),
        "unique_bars": len(unique),
        "duplicate_rows": duplicates,
        "first_bar_ms": unique[0],
        "last_bar_ms": unique[-1],
        "observed_span_intervals": expected_span,
        # GeckoTerminal omits minutes without trades. These are nonempty-bar
        # density metrics, NOT missing-data or coverage metrics.
        "nonempty_bar_slots_without_observation": missing_inside,
        "bar_density_inside_observed_span": len(unique) / expected_span if expected_span else None,
        "longest_consecutive_nonempty_bar_run": longest_run,
        "longest_gap_between_nonempty_bars_minutes": longest_gap,
        "misaligned_timestamps": misaligned_timestamps,
        "created_to_last_expected_intervals": created_expected,
        "observed_bars_since_creation": sum(
            first_expected <= ts <= unique[-1] for ts in unique
        ) if created_ts is not None and created_ts <= unique[-1] else 0,
        "nonempty_bar_slots_without_observation_since_creation": missing_since_creation,
    }


def summarize_coverage_intervals(intervals: list[tuple[int, int]]) -> dict:
    """Merge provider completeness claims; do not treat zero-trade minutes as missing data."""
    valid = sorted((int(start), int(end)) for start, end in intervals if end > start)
    if not valid:
        return {
            "audited_interval_count": len(intervals), "coverage_union_ms": 0,
            "first_coverage_ms": None, "last_coverage_ms": None,
            "uncovered_gap_count": None, "longest_uncovered_gap_ms": None,
            "coverage_union_ratio_inside_claim_span": None,
        }
    merged: list[list[int]] = []
    for start, end in valid:
        if not merged or start > merged[-1][1]:
            merged.append([start, end])
        else:
            merged[-1][1] = max(merged[-1][1], end)
    union_ms = sum(end - start for start, end in merged)
    span_ms = merged[-1][1] - merged[0][0]
    gaps = [merged[i + 1][0] - merged[i][1] for i in range(len(merged) - 1)]
    return {
        "audited_interval_count": len(intervals),
        "coverage_union_ms": union_ms,
        "first_coverage_ms": merged[0][0],
        "last_coverage_ms": merged[-1][1],
        "uncovered_gap_count": len(gaps),
        "longest_uncovered_gap_ms": max(gaps, default=0),
        "coverage_union_ratio_inside_claim_span": union_ms / span_ms if span_ms > 0 else 1.0,
    }


def conservative_coverage_intervals(bar_timestamps: list[int], parser_claims: list[tuple[int, int]],
                                    *, is_backfill: bool, interval_ms: int = MINUTE_MS) -> list[tuple[int, int]]:
    """Avoid the frozen parser's generic end-at-response-time claim on historical pages.

    For backfill pages, only claim the span actually bounded by returned bars.
    For live latest-page polls, retain the parser's claimed complete interval.
    This is a diagnostic-side correction; frozen normalization is not modified.
    """
    if is_backfill:
        if not bar_timestamps:
            return []
        return [(min(bar_timestamps), max(bar_timestamps) + interval_ms)]
    return [(int(start), int(end)) for start, end in parser_claims if end > start]


# Keep this list aligned with the frozen dispatch in data.normalize._parse.
# Unsupported endpoints are not malformed provider payloads; the normalizer
# currently reports them under MALFORMED_RECORD, so the diagnostic attributes
# those skips separately without changing the frozen normalization contract.
NORMALIZER_SUPPORTED_ENDPOINTS = frozenset({
    "gt.new_pools", "gt.trending", "gt.top_pools", "gt.pools_multi",
    "gt.trades", "gt.ohlcv", "gt.token_info", "ds.pairs",
})


def _entry_error(entry) -> bool:
    return bool(entry.error or entry.raw_id is None or (entry.status is not None and entry.status != 200))



def _latency_percentile(values: list[int], percentile: float) -> int | None:
    """Nearest-rank percentile; return UNKNOWN when no response timing exists."""
    if not values:
        return None
    ordered = sorted(values)
    index = max(0, min(len(ordered) - 1, math.ceil(percentile * len(ordered)) - 1))
    return ordered[index]


def summarize_provider_reliability(entries: list) -> dict:
    """Measure terminal outcomes and retry pressure separately.

    Internal query_not_applicable bookkeeping is excluded from provider request
    denominators. A terminal HTTP 200 counts as a successful response, not as
    proof that the payload or historical coverage is complete.
    """
    grouped: dict[str, list] = defaultdict(list)
    endpoint_grouped: dict[str, list] = defaultdict(list)
    for entry in entries:
        if entry.endpoint == "query_not_applicable" or entry.provider == "audit":
            continue
        grouped[str(entry.provider)].append(entry)
        endpoint_grouped[str(entry.endpoint)].append(entry)

    def summarise(items: list) -> dict:
        terminal_success = sum(
            1 for entry in items
            if not _entry_error(entry) and entry.status == 200 and entry.raw_id is not None
        )
        terminal_errors = len(items) - terminal_success
        attempts_total = 0
        retried_requests = 0
        retry_attempts = 0
        retry_statuses: Counter = Counter()
        retry_errors: Counter = Counter()
        latencies: list[int] = []
        for entry in items:
            attempts = entry.attempts if isinstance(entry.attempts, int) and entry.attempts > 0 else 1
            attempts_total += attempts
            if attempts > 1:
                retried_requests += 1
                retry_attempts += attempts - 1
            for attempt in entry.attempt_log or []:
                status = attempt.get("status")
                retry_statuses[str(status if status is not None else "UNKNOWN")] += 1
                error = str(attempt.get("error") or "UNKNOWN")
                retry_errors[error] += 1
            if isinstance(entry.request_ts, int) and isinstance(entry.response_ts, int):
                latencies.append(max(0, entry.response_ts - entry.request_ts))
        n = len(items)
        return {
            "requests": n,
            "terminal_successes": terminal_success,
            "terminal_errors": terminal_errors,
            "terminal_success_rate": terminal_success / n if n else None,
            "terminal_error_rate": terminal_errors / n if n else None,
            "total_attempts_including_retries": attempts_total,
            "requests_retried": retried_requests,
            "retry_attempts": retry_attempts,
            "retry_attempt_status_counts": dict(sorted(retry_statuses.items())),
            "retry_attempt_error_counts": dict(sorted(retry_errors.items())),
            "latency_ms_p50": _latency_percentile(latencies, 0.50),
            "latency_ms_p95": _latency_percentile(latencies, 0.95),
            "latency_samples": len(latencies),
        }

    by_provider = {key: summarise(value) for key, value in sorted(grouped.items())}
    by_endpoint = {key: summarise(value) for key, value in sorted(endpoint_grouped.items())}
    total = summarise([e for values in grouped.values() for e in values])
    if total["terminal_errors"]:
        status = "DEGRADED"
    elif total["retry_attempts"]:
        status = "RETRY_PRESSURE"
    else:
        status = "HEALTHY"
    return {
        "status": status,
        "denominator_excludes": ["query_not_applicable", "audit bookkeeping"],
        "overall": total,
        "by_provider": by_provider,
        "by_endpoint": by_endpoint,
        "interpretation": (
            "HTTP success is transport-level only. Payload validity, pagination, timestamp coverage, "
            "and usable liquidity are audited separately."
        ),
    }


def summarize_transaction_history(run_meta: dict, entries: list) -> dict:
    """Compare requested signature samples with actual transaction-body retrieval.

    This does not claim full-chain history: it measures only the enrichment
    requests declared by the archived run and the RPC records present in its
    manifest. Missing transactions remain missing, never zero activity.
    """
    enrichment = run_meta.get("enrichment") or []
    enrichment_by_purpose: dict[str, list] = defaultdict(list)
    for sample in enrichment:
        for purpose in ("funding", "liquidity"):
            item = sample.get(purpose)
            if isinstance(item, dict):
                enrichment_by_purpose[purpose].append(item)

    rpc_by_purpose: dict[str, list] = defaultdict(list)
    for entry in entries:
        if entry.endpoint in ("rpc.signatures", "rpc.transaction"):
            purpose = str((entry.context or {}).get("purpose") or "UNKNOWN")
            rpc_by_purpose[purpose].append(entry)

    purposes = sorted(set(enrichment_by_purpose) | set(rpc_by_purpose))
    by_purpose = {}
    totals = Counter()
    total_unique_addresses: set[str] = set()
    for purpose in purposes:
        samples = enrichment_by_purpose.get(purpose, [])
        signature_entries = [e for e in rpc_by_purpose.get(purpose, []) if e.endpoint == "rpc.signatures"]
        transaction_entries = [e for e in rpc_by_purpose.get(purpose, []) if e.endpoint == "rpc.transaction"]
        signatures_discovered = sum(
            int(item.get("signatures") or 0) for item in samples
            if isinstance(item.get("signatures"), (int, float))
        )
        transactions_declared_requested = sum(
            int(item.get("transactions_requested") or 0) for item in samples
            if isinstance(item.get("transactions_requested"), (int, float))
        )
        signatures_not_fetched = sum(
            int(item.get("signatures_not_fetched") or 0) for item in samples
            if isinstance(item.get("signatures_not_fetched"), (int, float))
        )
        truncated_samples = sum(bool(item.get("history_truncated")) for item in samples)
        pagination_gaps = sum(item.get("pagination_gap") not in (None, "", 0, False) for item in samples)
        successful_bodies = sum(
            1 for e in transaction_entries
            if not _entry_error(e) and e.status == 200 and e.raw_id is not None
        )
        failed_bodies = len(transaction_entries) - successful_bodies
        signature_values = {
            str((e.context or {}).get("signature"))
            for e in transaction_entries
            if (e.context or {}).get("signature")
        }
        addresses = {
            str(item.get("address")) for item in samples if item.get("address")
        }
        total_unique_addresses.update(addresses)
        by_purpose[purpose] = {
            "enrichment_sample_count": len(samples),
            "unique_addresses": len(addresses),
            "signature_discovery_request_count": len(signature_entries),
            "transaction_body_request_count": len(transaction_entries),
            "signatures_discovered_reported": signatures_discovered,
            "transaction_bodies_requested_reported": transactions_declared_requested,
            "transaction_bodies_successfully_returned": successful_bodies,
            "transaction_body_request_failures": failed_bodies,
            "unique_signature_ids_requested": len(signature_values),
            "signatures_not_fetched_reported": signatures_not_fetched,
            "history_truncated_sample_count": truncated_samples,
            "pagination_gap_sample_count": pagination_gaps,
            "request_count_matches_declared_body_requests": (
                len(transaction_entries) == transactions_declared_requested
                if samples else None
            ),
        }
        for key in (
            "enrichment_sample_count", "signature_discovery_request_count",
            "transaction_body_request_count", "transaction_bodies_requested_reported",
            "transaction_bodies_successfully_returned", "transaction_body_request_failures",
            "signatures_not_fetched_reported", "history_truncated_sample_count",
            "pagination_gap_sample_count",
        ):
            totals[key] += by_purpose[purpose][key]

    incomplete_reasons = []
    if totals["signatures_not_fetched_reported"]:
        incomplete_reasons.append("one or more discovered signatures were not fetched")
    if totals["history_truncated_sample_count"]:
        incomplete_reasons.append("one or more enrichment histories are explicitly marked truncated")
    if totals["pagination_gap_sample_count"]:
        incomplete_reasons.append("one or more enrichment histories report pagination gaps")
    if totals["transaction_body_request_failures"]:
        incomplete_reasons.append("one or more requested transaction bodies failed")
    if not enrichment:
        status = "UNKNOWN"
        incomplete_reasons.append("archive contains no enrichment completeness summary")
    elif incomplete_reasons:
        status = "INCOMPLETE"
    else:
        status = "SAMPLED_COMPLETE"
    return {
        "status": status,
        "scope": "enrichment transaction samples only; not a claim of complete chain history",
        "unique_enrichment_addresses": len(total_unique_addresses),
        "totals": dict(totals),
        "by_purpose": by_purpose,
        "incomplete_reasons": incomplete_reasons,
        "interpretation": (
            "SAMPLED_COMPLETE means the archive's declared sample was retrieved; it does not mean every "
            "signature for the address or every transaction for the token was retrieved."
        ),
    }


def audit_raw_archive_integrity(run_dir: Path, entries: list, raw: RawStore) -> dict:
    """Reconcile both response bodies and JSON-RPC request bodies with raw files."""
    raw_dir = run_dir / "raw"
    files = {
        path.name[:-8]: path
        for path in raw_dir.glob("*.json.gz")
        if path.is_file() and path.name.endswith(".json.gz")
    }
    response_ids = {entry.raw_id for entry in entries if entry.raw_id}
    request_ids = {entry.request_body_sha256 for entry in entries if entry.request_body_sha256}
    referenced_ids = response_ids | request_ids
    missing_files = sorted(referenced_ids - set(files))
    unreferenced_files = sorted(set(files) - referenced_ids)
    invalid_filenames = sorted(
        name for name in files
        if len(name) != 64 or any(ch not in "0123456789abcdef" for ch in name.lower())
    )
    hash_failures = []
    for raw_id in sorted(referenced_ids & set(files)):
        try:
            raw.body(raw_id)
        except (OSError, ValueError, EOFError) as exc:
            hash_failures.append({"raw_id": raw_id, "error": str(exc)[:240]})
    seqs = [entry.seq for entry in entries]
    duplicate_sequences = sorted(seq for seq, n in Counter(seqs).items() if n > 1)
    sequence_gaps = []
    if seqs:
        observed = set(seqs)
        sequence_gaps = sorted(set(range(min(observed), max(observed) + 1)) - observed)
    problems = []
    if missing_files:
        problems.append("manifest references raw body files that are absent")
    if unreferenced_files:
        problems.append("raw files are not referenced by response or request-body hashes")
    if invalid_filenames:
        problems.append("raw filenames are not SHA-256 hex digests")
    if hash_failures:
        problems.append("one or more raw bodies fail decompression or SHA-256 verification")
    if duplicate_sequences:
        problems.append("manifest sequence numbers are duplicated")
    if sequence_gaps:
        problems.append("manifest sequence numbers have gaps")
    return {
        "status": "PASS" if not problems else "FAIL",
        "manifest_entry_count": len(entries),
        "response_body_reference_count": len(response_ids),
        "request_body_reference_count": len(request_ids),
        "unique_referenced_body_count": len(referenced_ids),
        "raw_file_count": len(files),
        "missing_referenced_files": missing_files,
        "unreferenced_raw_files": unreferenced_files,
        "invalid_raw_filenames": invalid_filenames,
        "body_hash_failures": hash_failures,
        "duplicate_manifest_sequence_numbers": duplicate_sequences,
        "manifest_sequence_gaps": sequence_gaps,
        "problems": problems,
    }


def classify_historical_signal_readiness(
    archive_integrity: dict,
    provider_reliability: dict,
    transaction_history: dict,
    normalization_replay: dict,
    pool_reports: dict,
) -> dict:
    """Fail closed while separating archive checks from frozen cross-archive inference."""
    from . import phase3b_contract

    blockers = []
    if archive_integrity.get("status") != "PASS":
        blockers.append("raw archive integrity/reconciliation did not pass")
    if provider_reliability.get("status") != "HEALTHY":
        blockers.append("provider reliability is degraded or retry pressure remains")
    if transaction_history.get("status") != "SAMPLED_COMPLETE":
        blockers.append("transaction-history samples are incomplete or unknown")
    if normalization_replay.get("stored_vs_recomputed_match") is not True:
        blockers.append("canonical normalization replay is missing or does not match")
    if not pool_reports:
        blockers.append("no pool-level historical coverage was measured")
    # The frozen Phase 3C acquisition protocol specifies no additional liquidity
    # floor or per-token minimum. Statistical eligibility is defined by the frozen
    # Phase 3B hypothesis joins and must be evaluated across eligible archives;
    # this single-archive diagnostic cannot calculate that pooled sample.
    blockers.append(
        "cross-archive Phase 3C statistical evaluation has not established the frozen distinct-token sample per hypothesis"
    )
    return {
        "status": "NOT_READY",
        "eligible_pool_count": None,
        "eligibility_count_status": "NOT_EVALUATED_BY_SINGLE_ARCHIVE_DIAGNOSTIC",
        "pool_level_eligibility_policy": "NO_ADDITIONAL_LIQUIDITY_FLOOR_OR_PER_TOKEN_MINIMUM_IN_FROZEN_PHASE3C_PROTOCOL",
        "minimum_distinct_tokens_required": phase3b_contract.MIN_SAMPLE,
        "distinct_token_sample_status": "REQUIRES_CROSS_ARCHIVE_PHASE3C_PIPELINE",
        "blockers": blockers,
        "measured_pool_count": len(pool_reports),
        "normalization_replay_match": normalization_replay.get("stored_vs_recomputed_match"),
        "interpretation": (
            "This report cannot authorize model training or live trading. Provider reliability, transaction history, "
            "archive integrity, and normalization remain independent evidence checks. No extra pool-level liquidity "
            "threshold is invented; the frozen 85-token statistical gate is evaluated by the cross-archive Phase 3C pipeline."
        ),
    }


def audit_archive(run_dir: Path) -> dict:
    """Read raw requests and reparse OHLCV; return a deterministic diagnostic report."""
    raw = RawStore(str(run_dir))
    meta = raw.read_json("run.json") or {}
    selection_source, selected = phase3a_coverage.universe(raw)
    selected_by_pool = {p["pool"]: p for p in selected if p.get("pool")}
    entries = raw.entries()
    archive_integrity = audit_raw_archive_integrity(run_dir, entries, raw)
    provider_reliability = summarize_provider_reliability(entries)
    transaction_history = summarize_transaction_history(meta, entries)
    endpoint_totals: dict[str, Counter] = defaultdict(Counter)
    for entry in entries:
        endpoint = str(entry.endpoint)
        endpoint_totals[endpoint]["requests"] += 1
        if _entry_error(entry):
            endpoint_totals[endpoint]["failed_requests"] += 1
            error_text = str(entry.error or "")
            if "429" in error_text:
                failure_class = "HTTP_429"
            elif "403" in error_text:
                failure_class = "HTTP_403"
            elif entry.status is not None and entry.status != 200:
                failure_class = f"HTTP_{entry.status}"
            else:
                failure_class = "REQUEST_ERROR"
            endpoint_totals[endpoint][f"failure:{failure_class}"] += 1
        else:
            endpoint_totals[endpoint]["successful_responses"] += 1
    endpoint_accounting = {
        endpoint: {
            "requests": counts["requests"],
            "successful_responses": counts["successful_responses"],
            "failed_requests": counts["failed_requests"],
            "failure_classes": {
                key.removeprefix("failure:"): value
                for key, value in sorted(counts.items())
                if key.startswith("failure:")
            },
        }
        for endpoint, counts in sorted(endpoint_totals.items())
    }
    plan = meta.get("plan") or {}
    lag_ms = int(plan.get("lag_ms", 60_000))
    interval_ms = MINUTE_MS
    backfill_page_size_bars = 1000  # explicit limit passed to gt.path_ohlcv in acquire.backfill

    request_counts = Counter()
    error_counts = Counter()
    issue_counts = Counter()
    bars_by_pool: dict[str, list[int]] = defaultdict(list)
    bar_coverage_by_pool: dict[str, list[tuple[int, int]]] = defaultdict(list)
    bars_by_pool_token: dict[str, str] = {}
    response_counts = Counter()
    pool_errors: dict[str, Counter] = defaultdict(Counter)
    pages_by_pool: dict[str, set[int]] = defaultdict(set)
    poll_cycles_by_pool: dict[str, set[int]] = defaultdict(set)
    raw_bars_by_pool = Counter()

    for entry in entries:
        endpoint = entry.endpoint
        if endpoint != "gt.ohlcv":
            continue
        ctx = entry.context or {}
        pool = ctx.get("pool")
        if pool:
            request_counts["total_ohlcv"] += 1
            if "cycle" in ctx:
                request_counts["poll_ohlcv"] += 1
                try:
                    poll_cycles_by_pool[pool].add(int(ctx["cycle"]))
                except (TypeError, ValueError):
                    pass
            if "page" in ctx:
                request_counts["backfill_ohlcv"] += 1
                try:
                    pages_by_pool[pool].add(int(ctx["page"]))
                except (TypeError, ValueError):
                    pass
        if _entry_error(entry):
            request_counts["failed_ohlcv"] += 1
            error_counts[str(entry.error or f"HTTP {entry.status}")] += 1
            if pool:
                pool_errors[pool]["failed_requests"] += 1
            continue
        response_counts["successful_ohlcv"] += 1
        parsed = gt.parse_ohlcv(entry, raw.body(entry.raw_id), lag_ms)
        request_bar_timestamps = []
        request_coverage_claims = []
        for issue in parsed.issues:
            issue_counts[issue.code] += 1
            if pool:
                pool_errors[pool][issue.code] += 1
        for record in parsed.records:
            if type(record).__name__ == "ProviderBar":
                bars_by_pool[record.pool].append(int(record.ts))
                request_bar_timestamps.append(int(record.ts))
                bars_by_pool_token[record.pool] = record.token
                raw_bars_by_pool[record.pool] += 1
            elif type(record).__name__ == "Coverage" and record.kind == "bars":
                request_coverage_claims.append((int(record.start_ts), int(record.end_ts)))
        if pool:
            audited_intervals = conservative_coverage_intervals(
                request_bar_timestamps, request_coverage_claims,
                is_backfill=("page" in ctx), interval_ms=interval_ms,
            )
            bar_coverage_by_pool[pool].extend(audited_intervals)
            if "page" in ctx:
                if request_bar_timestamps:
                    request_counts["backfill_coverage_intervals_clipped"] += 1
                else:
                    request_counts["backfill_pages_without_valid_bars"] += 1

    # Re-run the frozen normalizer over the same immutable archive to compare its
    # output with the archived normalization summary and expose issue examples.
    _, normalization_report = normalize_all(str(run_dir), lag_ms)
    stored_normalization = raw.read_json("normalize_stdout.json") or {}
    recomputed_issues = normalization_report.issues
    recomputed_records = normalization_report.records
    stored_vs_recomputed_match = bool(stored_normalization) and (
        stored_normalization.get("dataset_sha256") == normalization_report.dataset_sha256
        and stored_normalization.get("issues") == recomputed_issues
        and stored_normalization.get("records") == recomputed_records
    )
    entry_by_raw_id = {entry.raw_id: entry for entry in entries if entry.raw_id}
    unsupported_endpoint_counts = Counter(
        entry.endpoint for entry in entries
        if not _entry_error(entry)
        and entry.endpoint not in NORMALIZER_SUPPORTED_ENDPOINTS
    )
    issue_samples = {}
    for code, samples in normalization_report.issue_samples.items():
        enriched = []
        for sample in samples[:5]:
            item = {**sample, "detail": str(sample.get("detail", ""))[:400]}
            entry = entry_by_raw_id.get(sample.get("raw_id"))
            if entry is not None:
                item["endpoint"] = entry.endpoint
            detail = str(sample.get("detail", ""))
            if detail.startswith("no parser for "):
                item["classification"] = "UNSUPPORTED_NORMALIZER_ENDPOINT"
            elif detail.startswith("body is not JSON") or detail.startswith("response has no 'data' member"):
                item["classification"] = "INVALID_PROVIDER_PAYLOAD"
            else:
                item["classification"] = "RECORD_VALIDATION_OR_SCHEMA"
            enriched.append(item)
        issue_samples[code] = enriched

    malformed_record_count = int(recomputed_issues.get("MALFORMED_RECORD", 0))
    unsupported_endpoint_response_count = int(sum(unsupported_endpoint_counts.values()))
    normalization_issue_attribution = {
        "unsupported_endpoint_response_counts": dict(sorted(unsupported_endpoint_counts.items())),
        "unsupported_endpoint_response_count": unsupported_endpoint_response_count,
        "malformed_record_issue_count": malformed_record_count,
        "malformed_record_residual_count_after_unsupported_endpoints": (
            malformed_record_count - unsupported_endpoint_response_count
        ),
        "malformed_record_issues_fully_explained_by_unsupported_endpoints": (
            unsupported_endpoint_response_count == malformed_record_count
        ),
        "interpretation": (
            "Unsupported endpoint responses are currently labelled MALFORMED_RECORD by the frozen normalizer. "
            "This diagnostic attributes them separately; it does not rewrite or suppress normalization issues."
        ),
    }

    pool_reports = {}
    for pool in sorted(set(selected_by_pool) | set(bars_by_pool) | set(pool_errors) | set(bar_coverage_by_pool)):
        selected_item = selected_by_pool.get(pool, {})
        created_ts = selected_item.get("created_ts")
        if not isinstance(created_ts, int):
            created_ts = None
        timestamps = bars_by_pool.get(pool, [])
        stats = summarize_timestamps(timestamps, created_ts=created_ts, interval_ms=interval_ms)
        coverage_stats = summarize_coverage_intervals(bar_coverage_by_pool.get(pool, []))
        cycles = sorted(poll_cycles_by_pool.get(pool, set()))
        pages = sorted(pages_by_pool.get(pool, set()))
        pool_reports[pool] = {
            "token": selected_item.get("token") or bars_by_pool_token.get(pool),
            "selected": pool in selected_by_pool,
            "ohlcv_requests": 1 * (sum(1 for e in entries if e.endpoint == "gt.ohlcv" and (e.context or {}).get("pool") == pool)),
            "backfill_page_indices": pages,
            "poll_cycle_indices": cycles,
            "first_poll_cycle": cycles[0] if cycles else None,
            "last_poll_cycle": cycles[-1] if cycles else None,
            "request_errors": dict(sorted(pool_errors.get(pool, {}).items())),
            "bar_coverage_claims": coverage_stats,
            **stats,
        }

    cycles_raw = meta.get("poll_window_cycles")
    cycle_source = "poll_window_cycles"
    if not isinstance(cycles_raw, (int, float)):
        # Older archives used the same counter under `cycles` but did not save
        # the actual elapsed polling-window duration.
        cycles_raw = meta.get("cycles")
        cycle_source = "legacy_cycles_field"
    cycles = int(cycles_raw) if isinstance(cycles_raw, (int, float)) else None
    every = max(1, int(plan.get("ohlcv_every") or 1))
    expected_poll_calls = math.ceil(cycles / every) * len(selected) if selected and cycles is not None else None
    actual_poll_calls = int(request_counts["poll_ohlcv"])
    duration_s = plan.get("duration_s")
    elapsed_s = meta.get("poll_window_elapsed_s")
    historical_signal_readiness = classify_historical_signal_readiness(
        archive_integrity,
        provider_reliability,
        transaction_history,
        {
            "stored_vs_recomputed_match": stored_vs_recomputed_match if stored_normalization else None,
        },
        pool_reports,
    )
    return {
        "schema_version": 2,
        "diagnostic_only": True,
        "archive_integrity": archive_integrity,
        "provider_reliability": provider_reliability,
        "transaction_history_completeness": transaction_history,
        "historical_signal_readiness": historical_signal_readiness,
        "archive": run_dir.name,
        "run_id": meta.get("run_id"),
        "code_version": meta.get("code_version"),
        "acquisition_status": meta.get("status", "UNKNOWN"),
        "selection_source": selection_source,
        "selected_pool_count": len(selected),
        "run_window": {
            "configured_duration_s": duration_s,
            "observed_elapsed_s": elapsed_s,
            "completed_cycles": cycles,
            "cycle_telemetry_available": cycles is not None,
            "cycle_count_source": cycle_source if cycles is not None else None,
            "window_duration_reached": (
                elapsed_s >= duration_s if isinstance(elapsed_s, (int, float))
                and isinstance(duration_s, (int, float)) else None
            ),
        },
        "configured_history_cap": {
            "backfill_pages_per_pool": plan.get("backfill_pages"),
            "provider_bars_per_page": backfill_page_size_bars,
            "maximum_requested_minute_bars_per_pool": (
                int(plan["backfill_pages"]) * backfill_page_size_bars
                if isinstance(plan.get("backfill_pages"), (int, float)) else None
            ),
            "maximum_requested_history_hours_per_pool": (
                int(plan["backfill_pages"]) * backfill_page_size_bars / 60
                if isinstance(plan.get("backfill_pages"), (int, float)) else None
            ),
            "interpretation": "Configured upper bound only; actual bars can be lower because pools are younger, provider pages are short, requests fail, or validation rejects records.",
        },
        "endpoint_accounting": endpoint_accounting,
        "request_accounting": {
            "ohlcv_requests_total": int(request_counts["total_ohlcv"]),
            "ohlcv_backfill_requests": int(request_counts["backfill_ohlcv"]),
            "ohlcv_poll_requests": actual_poll_calls,
            "ohlcv_failed_requests": int(request_counts["failed_ohlcv"]),
            "backfill_coverage_intervals_clipped": int(request_counts["backfill_coverage_intervals_clipped"]),
            "backfill_pages_without_valid_bars": int(request_counts["backfill_pages_without_valid_bars"]),
            "expected_poll_requests_from_cycle_count": expected_poll_calls,
            "poll_request_count_matches_cycle_count": (
                actual_poll_calls == expected_poll_calls if expected_poll_calls is not None else None
            ),
            "successful_ohlcv_responses": int(response_counts["successful_ohlcv"]),
            "provider_error_details": dict(sorted(error_counts.items())),
            "parsed_bar_rows": sum(raw_bars_by_pool.values()),
            "parser_issue_counts": dict(sorted(issue_counts.items())),
        },
        "normalization_replay": {
            "stored_summary_present": bool(stored_normalization),
            "stored_vs_recomputed_match": stored_vs_recomputed_match if stored_normalization else None,
            "stored_dataset_sha256": stored_normalization.get("dataset_sha256"),
            "recomputed_dataset_sha256": normalization_report.dataset_sha256,
            "stored_issue_counts": stored_normalization.get("issues"),
            "recomputed_issue_counts": recomputed_issues,
            "stored_record_counts": stored_normalization.get("records"),
            "recomputed_record_counts": recomputed_records,
            "issue_samples": issue_samples,
        },
        "normalization_issue_attribution": normalization_issue_attribution,
        "pools": pool_reports,
        "limitations": [
            "GeckoTerminal omits minute bars when no trades occur. Missing nonempty bars inside a claimed interval are not labelled missing data; the report separately measures audited completeness-interval coverage and nonempty-bar density.",
            "The frozen parser's generic bars Coverage record ends at response time even for historical before_timestamp pages. This diagnostic clips historical-page coverage to the returned bar range without changing the frozen parser.",
            "Coverage claims indicate completeness of nonempty bars, not executable liquidity. A zero-trade minute may be complete data and still be a liquidity/tradability warning.",
            "The created-to-last interval count is a density diagnostic, not a claim that every minute after pool creation should trade.",
            "No readiness thresholds are inferred or changed by this tool.",
            "Repeated bars across polling responses are reported as duplicate observations, not silently removed from the raw archive.",
            "Historical OHLCV backfill uses a provider page size of 1000 minute bars; configured page count therefore caps the maximum requested history and may be insufficient for multi-day requirements.",
        ],
    }


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("run_dir", type=Path, help="Path to one archived Phase 3C run")
    parser.add_argument("--out", type=Path, help="Optional JSON output path")
    args = parser.parse_args()
    report = audit_archive(args.run_dir)
    rendered = json.dumps(report, sort_keys=True, indent=2)
    if args.out:
        args.out.parent.mkdir(parents=True, exist_ok=True)
        args.out.write_text(rendered + "\n", encoding="utf-8")
    print(rendered)


if __name__ == "__main__":
    main()
