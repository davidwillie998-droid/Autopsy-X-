import io
import json
import urllib.error

import pytest

from autopsyx.providers.base import ProviderError
from autopsyx.providers.http import CircuitBreaker, HttpClient, TokenBucket


class _Resp(io.BytesIO):
    def __enter__(self):
        return self

    def __exit__(self, *a):
        return False


def _client(responses, sleeps):
    calls = []

    def opener(req, timeout):
        calls.append(req.full_url)
        r = responses.pop(0)
        if isinstance(r, Exception):
            raise r
        return _Resp(json.dumps(r).encode())

    clock = [0.0]
    bucket = TokenBucket(1000, 10, clock=lambda: clock[0], sleep=lambda s: None)
    c = HttpClient("https://x.test", bucket, sleep=sleeps.append, opener=opener,
                   breaker=CircuitBreaker(threshold=3, cooldown_s=60, clock=lambda: clock[0]))
    return c, calls


def _http(code, retry_after=None):
    hdrs = {"Retry-After": retry_after} if retry_after else {}
    return urllib.error.HTTPError("u", code, "err", hdrs, None)


def test_retries_rate_limit_and_honours_retry_after():
    sleeps = []
    c, calls = _client([_http(429, "7"), {"ok": 1}], sleeps)
    assert c.get_json("/a") == {"ok": 1}
    assert len(calls) == 2 and 7 <= sleeps[0] <= 7 * 1.2


def test_client_error_fails_fast():
    c, calls = _client([_http(404)], [])
    with pytest.raises(ProviderError) as e:
        c.get_json("/a")
    assert not e.value.retryable and len(calls) == 1


def test_exhausted_retries_raise_retryable():
    c, calls = _client([_http(503)] * 5, [])
    with pytest.raises(ProviderError) as e:
        c.get_json("/a")
    assert e.value.retryable and len(calls) == 5


def test_circuit_opens_after_failures():
    cb = CircuitBreaker(threshold=2, cooldown_s=10, clock=lambda: 0.0)
    cb.record(False)
    cb.record(False)
    assert not cb.allow()
    later = CircuitBreaker(threshold=1, cooldown_s=10, clock=iter([0.0, 11.0]).__next__)
    later.record(False)
    assert later.allow()


def test_token_bucket_waits_when_empty():
    t = [0.0]
    waited = []

    def sleep(s):
        waited.append(s)
        t[0] += s

    b = TokenBucket(2.0, 1, clock=lambda: t[0], sleep=sleep)
    b.acquire()
    b.acquire()
    assert waited and waited[0] == pytest.approx(0.5)


def test_token_bucket_does_not_livelock_on_float_rounding():
    """Regression: with a clock that only advances by the requested sleep, the leftover
    0.999... balance made acquire() spin forever."""
    t = [0.0]

    def sleep(s):
        t[0] += s
    b = TokenBucket(0.11, 1, clock=lambda: t[0], sleep=sleep)
    for _ in range(50):
        b.acquire()
    assert t[0] == pytest.approx(49 / 0.11, rel=1e-6)
