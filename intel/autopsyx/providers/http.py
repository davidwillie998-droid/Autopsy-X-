"""Transport utilities every live adapter must use: retries, rate limits,
circuit breaking. Adapters never call urllib directly."""
from __future__ import annotations

import json
import logging
import random
import threading
import time
import urllib.error
import urllib.request
from dataclasses import dataclass, field
from typing import Any, Callable

from .base import ProviderError

log = logging.getLogger("autopsyx.http")


class TokenBucket:
    """Client-side rate limiter. Set rate below the vendor's published limit."""

    def __init__(self, rate_per_s: float, burst: int, clock: Callable[[], float] = time.monotonic,
                 sleep: Callable[[float], None] = time.sleep):
        self.rate = rate_per_s
        self.capacity = burst
        self.tokens = float(burst)
        self._clock = clock
        self._sleep = sleep
        self._last = clock()
        self._lock = threading.Lock()

    def acquire(self) -> None:
        with self._lock:
            while True:
                now = self._clock()
                self.tokens = min(self.capacity, self.tokens + (now - self._last) * self.rate)
                self._last = now
                if self.tokens >= 1:
                    self.tokens -= 1
                    return
                # Wait for the missing fraction, then consume the token outright. Re-checking a
                # rounded balance (0.999...) livelocked with coarse clocks (found in Phase 2 tests).
                wait = (1 - self.tokens) / self.rate
                self._sleep(wait)
                self.tokens = 0.0
                self._last = max(self._clock(), self._last + wait)
                return


@dataclass
class CircuitBreaker:
    """Opens after ``threshold`` consecutive failures; half-opens after ``cooldown_s``."""

    threshold: int = 5
    cooldown_s: float = 60.0
    clock: Callable[[], float] = time.monotonic
    failures: int = 0
    opened_at: float | None = None

    def allow(self) -> bool:
        if self.opened_at is None:
            return True
        return self.clock() - self.opened_at >= self.cooldown_s

    def record(self, success: bool) -> None:
        if success:
            self.failures, self.opened_at = 0, None
        else:
            self.failures += 1
            if self.failures >= self.threshold:
                self.opened_at = self.clock()


@dataclass(frozen=True)
class RawResponse:
    """Exactly what came back, plus the two clocks that matter."""

    url: str
    status: int
    body: bytes
    content_type: str
    request_ts: int  # ms, local clock when the request was sent
    response_ts: int  # ms, local clock when the body was fully read (= available_time)
    attempts: int


@dataclass
class HttpClient:
    """Guarantees (each backed by tests/test_transport.py):

    * at most ``max_retries`` + 1 attempts per call
    * retries only HTTP 429, HTTP 5xx, connection errors, timeouts, and
      bodies that fail JSON decoding (``get_json`` only)
    * other 4xx fail immediately with ``ProviderError(retryable=False)``
    * backoff starts at ``backoff_s`` and doubles, plus up to 20% jitter;
      a ``Retry-After`` header replaces the computed delay
    * every retry and every final failure is logged on ``autopsyx.http``
    * the circuit breaker refuses calls while open and lets one through
      after its cooldown; a success closes it
    * with ``adaptive_min_rate`` set, every HTTP 429 halves the token-bucket
      rate (never below the minimum) and every success raises it by
      ``adaptive_step`` (never above the configured rate). Added after the
      first Phase 2 acquisition: a shared CI runner IP was throttled far
      below the vendor's published limit
    """

    base_url: str
    limiter: TokenBucket
    headers: dict[str, str] = field(default_factory=dict)
    max_retries: int = 4
    timeout_s: float = 10.0
    backoff_s: float = 1.0
    breaker: CircuitBreaker = field(default_factory=CircuitBreaker)
    sleep: Callable[[float], None] = time.sleep
    opener: Callable[..., Any] = urllib.request.urlopen
    now_ms: Callable[[], int] = field(default=lambda: int(time.time() * 1000))
    jitter: Callable[[], float] = random.random
    adaptive_min_rate: float | None = None
    adaptive_step: float = 0.01
    max_rate: float | None = None

    def _adapt(self, throttled: bool) -> None:
        if self.adaptive_min_rate is None:
            return
        if self.max_rate is None:
            self.max_rate = self.limiter.rate
        old = self.limiter.rate
        if throttled:
            self.limiter.rate = max(self.adaptive_min_rate, old * 0.5)
        else:
            self.limiter.rate = min(self.max_rate, old + self.adaptive_step)
        if self.limiter.rate != old and throttled:
            log.warning("rate reduced", extra={"fields": {"from_per_s": round(old, 4),
                                                          "to_per_s": round(self.limiter.rate, 4)}})

    def get_raw(self, path: str) -> RawResponse:
        url = self.base_url + path
        if not self.breaker.allow():
            log.error("circuit open", extra={"fields": {"url": url}})
            raise ProviderError(f"circuit open for {self.base_url}", retryable=True)
        delay = self.backoff_s
        last: Exception | None = None
        for attempt in range(1, self.max_retries + 2):
            self.limiter.acquire()
            t0 = self.now_ms()
            try:
                req = urllib.request.Request(url, headers=self.headers)
                with self.opener(req, timeout=self.timeout_s) as resp:
                    body = resp.read()
                    status = getattr(resp, "status", 200)
                    ctype = resp.headers.get("Content-Type", "") if getattr(resp, "headers", None) else ""
                self.breaker.record(True)
                self._adapt(False)
                return RawResponse(url, status, body, ctype, t0, self.now_ms(), attempt)
            except urllib.error.HTTPError as exc:
                last = exc
                retryable = exc.code == 429 or 500 <= exc.code < 600
                if exc.code == 429:
                    self._adapt(True)
                if not retryable:
                    self.breaker.record(False)
                    log.error("non-retryable HTTP error", extra={"fields": {"url": url, "status": exc.code}})
                    raise ProviderError(f"HTTP {exc.code} {path}", retryable=False) from exc
                wait = _retry_after(exc) or delay
            except (urllib.error.URLError, TimeoutError, OSError) as exc:
                last = exc
                wait = delay
            self.breaker.record(False)
            if attempt <= self.max_retries:
                pause = wait + wait * 0.2 * self.jitter()
                log.warning("retry", extra={"fields": {"url": url, "attempt": attempt, "wait_s": round(pause, 3),
                                                       "error": str(last)}})
                self.sleep(pause)
                delay *= 2
        rate = isinstance(last, urllib.error.HTTPError) and last.code == 429
        log.error("retries exhausted", extra={"fields": {"url": url, "error": str(last), "rate_limited": rate}})
        raise ProviderError(f"exhausted retries for {path}: {last}", retryable=True, rate_limited=rate)

    def get_json(self, path: str) -> Any:
        raw = self.get_raw(path)
        try:
            return json.loads(raw.body.decode())
        except (UnicodeDecodeError, json.JSONDecodeError) as exc:
            raise ProviderError(f"malformed JSON from {path}: {exc}", retryable=False) from exc


def _retry_after(exc: urllib.error.HTTPError) -> float | None:
    val = exc.headers.get("Retry-After") if exc.headers else None
    try:
        return float(val) if val else None
    except ValueError:
        return None
