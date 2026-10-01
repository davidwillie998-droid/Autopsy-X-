"""Provider and freshness telemetry, computed from the raw manifest (evidence layer).

Nothing here is computed by a renderer; the Phase 3A report only prints
what these functions put into the evidence.

Freshness policy. The project has exactly one approved freshness threshold:
``data_quality.max_price_age_ms`` (market data older than this is
STALE_DATA). The policy applies it to the market endpoints polled every
cycle and to nothing else. Endpoints without an approved threshold report
their ages with ``compliance = NOT_APPLICABLE``; no threshold is invented
for them.
"""
from __future__ import annotations

import hashlib
import json
from collections import Counter, defaultdict

from ..core.config import Config
from ..data.raw import ManifestEntry

MARKET_ENDPOINTS = ("gt.pools_multi", "ds.pairs", "gt.trades", "gt.ohlcv")


def freshness_policy(cfg: Config) -> dict:
    return {
        "max_age_ms": cfg.section("data_quality")["max_price_age_ms"],
        "threshold_source": "config/default.toml [data_quality] max_price_age_ms",
        "governed_endpoints": list(MARKET_ENDPOINTS),
        "age_definition": "at each request to an endpoint for an entity, request_ts minus the response_ts of the "
                          "latest earlier successful response for the same endpoint and entity",
        "stale_rule": "age > max_age_ms is STALE; the first request for an entity has no age and is not counted",
        "ungoverned_endpoints": "ages reported, compliance NOT_APPLICABLE (no approved threshold)",
    }


def policy_fingerprint(policy: dict) -> str:
    return hashlib.sha256(json.dumps(policy, sort_keys=True).encode()).hexdigest()


def _entity(e: ManifestEntry) -> str:
    c = e.context or {}
    return str(c.get("signature") or c.get("address") or c.get("pool") or c.get("token") or "*")


def _pct(xs: list[int], q: float):
    if not xs:
        return None
    xs = sorted(xs)
    return xs[min(len(xs) - 1, int(q * len(xs)))]


def provider_telemetry(entries: list[ManifestEntry]) -> dict:
    """Per provider: requests, outcomes, HTTP status mix, retries, backoff, rate-limit, latency."""
    by: dict[str, list[ManifestEntry]] = defaultdict(list)
    for e in entries:
        if e.provider != "audit":
            by[e.provider].append(e)
    out = {}
    for p in sorted(by):
        es = by[p]
        ok = [e for e in es if e.error is None]
        bad = [e for e in es if e.error is not None]
        statuses: dict[str, int] = defaultdict(int)
        for e in es:
            statuses[str(e.status) if e.status is not None else "none"] += 1
        failed_attempts = [a for e in es for a in e.attempt_log]
        # Phase 2 manifests have no attempt_log: retries before a success are still
        # known from ``attempts``; for failures without a log they are not.
        retries_ok = sum((e.attempts or 1) - 1 for e in ok)
        logged_bad = [e for e in bad if e.attempt_log]
        lat = [e.response_ts - e.request_ts for e in ok if e.response_ts is not None]
        rate_limited = sum(1 for a in failed_attempts if a.get("status") == 429)
        out[p] = {
            "requests": len(es), "successes": len(ok), "errors": len(bad),
            "error_rate": round(len(bad) / len(es), 6) if es else None,
            "status_counts": dict(sorted(statuses.items())),
            "retries_before_success": retries_ok,
            "failed_attempts_logged": len(failed_attempts),
            "failures_without_attempt_log": len(bad) - len(logged_bad),
            "rate_limited_attempts": rate_limited,
            "rate_limited_state": "OBSERVED" if not bad or len(logged_bad) == len(bad) else "PARTIAL",
            "backoff_s_total": round(sum(float(a.get("wait_s") or 0) for a in failed_attempts), 3),
            "circuit_waits": sum(int((e.context or {}).get("circuit_waits", 0)) for e in es),
            "latency_ms": {"p50": _pct(lat, 0.5), "p95": _pct(lat, 0.95), "max": max(lat) if lat else None},
            "endpoints": dict(sorted(Counter(e.endpoint for e in es).items())),
        }
    return out


def freshness(entries: list[ManifestEntry], policy: dict) -> dict:
    """Per endpoint: age distribution, and STALE counts where the policy governs it."""
    last_ok: dict[tuple[str, str], int] = {}
    ages: dict[str, list[int]] = defaultdict(list)
    for e in sorted(entries, key=lambda x: (x.request_ts, x.seq)):
        if e.provider == "audit":
            continue
        k = (e.endpoint, _entity(e))
        if k in last_ok:
            ages[e.endpoint].append(e.request_ts - last_ok[k])
        if e.error is None and e.response_ts is not None:
            last_ok[k] = e.response_ts
    out = {}
    lim = policy["max_age_ms"]
    for ep in sorted(ages):
        a = ages[ep]
        governed = ep in policy["governed_endpoints"]
        stale = sum(1 for x in a if x > lim) if governed else None
        out[ep] = {"evaluations": len(a), "age_ms": {"p50": _pct(a, 0.5), "p95": _pct(a, 0.95), "max": max(a)},
                   "governed": governed, "stale": stale,
                   "compliance": round((len(a) - stale) / len(a), 6) if governed and a else "NOT_APPLICABLE"}
    gov = [v for v in out.values() if v["governed"]]
    n = sum(v["evaluations"] for v in gov)
    s = sum(v["stale"] for v in gov)
    return {"endpoints": out, "governed_evaluations": n, "governed_stale": s,
            "governed_compliance": round((n - s) / n, 6) if n else "NOT_OBSERVED"}


# Fingerprint of the policy above as frozen for Phase 3A. A change to the
# policy (or to the threshold it reads) fails the freeze test and must be
# made, and explained, deliberately.
FROZEN_POLICY_FINGERPRINT = "58fe8ee8476b824fde285065d8dafbebb594f9bf1cd0df04091823d13b9881ff"


def policy_freeze(cfg: Config) -> dict:
    fp = policy_fingerprint(freshness_policy(cfg))
    return {"fingerprint": fp, "frozen": FROZEN_POLICY_FINGERPRINT, "identical_to_frozen": fp == FROZEN_POLICY_FINGERPRINT}
