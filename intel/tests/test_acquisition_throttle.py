"""Regression guard for evidence-driven GeckoTerminal pacing defaults."""

import pytest

from autopsyx.data.acquire import Plan, default_clients
from autopsyx.data.providers import geckoterminal as gt


def test_geckoterminal_default_pacing_reduces_burst_and_rate():
    plan = Plan()
    clients = default_clients(plan, lambda: 0)
    client = clients[gt.NAME]

    # Archive audit found substantial HTTP 429 retry pressure. Start more
    # conservatively and let the existing adaptive limiter respond to evidence.
    assert plan.gt_rate_per_s == pytest.approx(0.25)
    assert client.limiter.rate == pytest.approx(0.25)
    assert client.limiter.capacity == 1
    assert client.adaptive_min_rate == pytest.approx(0.05)
    assert client.max_retries == 3


def test_geckoterminal_adaptive_rate_stays_within_configured_bounds():
    plan = Plan()
    client = default_clients(plan, lambda: 0)[gt.NAME]

    client._adapt(True)
    assert client.limiter.rate == pytest.approx(0.125)
    client._adapt(False)
    assert client.limiter.rate == pytest.approx(0.13)
    for _ in range(100):
        client._adapt(False)
    assert client.limiter.rate <= 0.25
    assert client.limiter.rate >= 0.05
