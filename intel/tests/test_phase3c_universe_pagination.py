from types import SimpleNamespace

from autopsyx.data import acquire


class FakeRaw:
    def __init__(self):
        self.json = {}
        self.records = []

    def write_json(self, name, value):
        self.json[name] = value

    def record(self, **kwargs):
        self.records.append(kwargs)


class FakeFetcher:
    def __init__(self):
        self.raw = FakeRaw()
        self.calls = []

    def now_ms(self):
        return 1_800_000_000_000

    def get(self, provider, endpoint, url, context):
        self.calls.append((endpoint, url, context))
        return SimpleNamespace(url=url, request_ts=1), None


def test_universe_discovery_paginates_all_candidate_strata(monkeypatch):
    monkeypatch.setattr(acquire, "_pools_from", lambda entry, body: [])
    fetcher = FakeFetcher()
    plan = acquire.Plan(new_pool_pages=3, strata={
        "young": 1, "quiet_young": 0, "trending": 1, "established": 1
    })

    selection = acquire.select_universe(fetcher, plan)

    by_endpoint = {}
    for endpoint, url, context in fetcher.calls:
        by_endpoint.setdefault(endpoint, []).append(context.get("page"))
    assert by_endpoint["gt.new_pools"] == [1, 2, 3]
    assert by_endpoint["gt.trending"] == [1, 2, 3]
    assert by_endpoint["gt.top_pools"] == [1, 2, 3]
    assert selection["candidates"] == {
        "young": 0, "trending": 0, "established": 0, "quiet_young": 0
    }
    assert fetcher.raw.json["selection.json"] == selection
