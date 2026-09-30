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
                self._sleep((1 - self.tokens) / self.rate)


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


@dataclass
class HttpClient:
    base_url: str
    limiter: TokenBucket
    headers: dict[str, str] = field(default_factory=dict)
    max_retries: int = 4
    timeout_s: float = 10.0
    breaker: CircuitBreaker = field(default_factory=CircuitBreaker)
    sleep: Callable[[float], None] = time.sleep
    opener: Callable[..., Any] = urllib.request.urlopen

    def get_json(self, path: str) -> Any:
        if not self.breaker.allow():
            raise ProviderError(f"circuit open for {self.base_url}", retryable=True)
        delay = 1.0
        last: Exception | None = None
        for attempt in range(self.max_retries + 1):
            self.limiter.acquire()
            try:
                req = urllib.request.Request(self.base_url + path, headers=self.headers)
                with self.opener(req, timeout=self.timeout_s) as resp:
                    body = json.loads(resp.read().decode())
                self.breaker.record(True)
                return body
            except urllib.error.HTTPError as exc:
                last = exc
                retryable = exc.code == 429 or 500 <= exc.code < 600
                if not retryable:
                    self.breaker.record(False)
                    raise ProviderError(f"HTTP {exc.code} {path}", retryable=False) from exc
                wait = _retry_after(exc) or delay
            except (urllib.error.URLError, TimeoutError, json.JSONDecodeError) as exc:
                last = exc
                wait = delay
            self.breaker.record(False)
            if attempt < self.max_retries:
                jitter = wait * 0.2 * random.random()
                log.warning("retry %s in %.1fs (%s)", path, wait + jitter, last)
                self.sleep(wait + jitter)
                delay *= 2
        raise ProviderError(f"exhausted retries for {path}: {last}", retryable=True,
                            rate_limited=isinstance(last, urllib.error.HTTPError) and last.code == 429)


def _retry_after(exc: urllib.error.HTTPError) -> float | None:
    val = exc.headers.get("Retry-After") if exc.headers else None
    try:
        return float(val) if val else None
    except ValueError:
        return None
