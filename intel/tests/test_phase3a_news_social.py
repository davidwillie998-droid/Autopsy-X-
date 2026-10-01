"""News / social acquisition: provenance and the three clocks, no sentiment."""
import json
from datetime import datetime, timezone

from autopsyx.core.observation import Availability as A
from autopsyx.data import acquire
from autopsyx.data.normalize3a import normalize_phase3a
from autopsyx.data.providers import news_social as ns
from autopsyx.data.raw import RawStore
from autopsyx.providers.http import CircuitBreaker, HttpClient, TokenBucket
from autopsyx.providers.store import EventStore

from phase2_fakes import _Resp, http_error

TOKEN = "9WzDXwBbmkg8ZTbNMqUxvQRAyrZzDsGYdLVL9zYtAWWM"
T0 = 1_790_000_000_000  # 2026-09-21T13:46:40Z
GDELT_BODY = json.dumps({"articles": [
    {"url": "https://news.example/a", "title": "Token story", "seendate": "20260921T120000Z",
     "domain": "news.example", "language": "English", "sourcecountry": "US"}]}).encode()
REDDIT_BODY = json.dumps({"data": {"children": [
    {"data": {"name": "t3_abc", "author": "someone", "created_utc": 1_789_990_000.0, "permalink": "/r/solana/comments/abc/x/",
              "subreddit": "solana", "title": "CA " + TOKEN, "selftext": "", "url": "https://x.example"}},
    {"data": {"name": "t3_def", "author": "[deleted]", "created_utc": 1_789_991_000, "permalink": "/r/solana/comments/def/y/",
              "subreddit": "solana", "title": "t", "selftext": "s"}}]}}).encode()


class Net:
    def __init__(self, clock, answers):
        self.clock, self.answers = clock, answers

    def __call__(self, req, timeout):
        self.clock[0] += 200
        for key, queue in self.answers.items():
            if key in req.full_url and queue:
                a = queue.pop(0)
                if isinstance(a, Exception):
                    raise a
                return _Resp(a)
        raise AssertionError(req.full_url)


def run(tmp_path, gdelt, reddit, symbol="TOKEN"):
    clock = [T0]
    net = Net(clock, {"gdeltproject": list(gdelt), "reddit": list(reddit)})
    mk = lambda base: HttpClient(base, TokenBucket(1e6, 1000, clock=lambda: 0.0, sleep=lambda s: None), {},
                                 max_retries=1, sleep=lambda s: None, opener=net,
                                 breaker=CircuitBreaker(50, 1, clock=lambda: 0.0), now_ms=lambda: clock[0])
    f = acquire.Fetcher(RawStore(tmp_path), {ns.GDELT: mk(ns.GDELT_BASE), ns.REDDIT: mk(ns.REDDIT_BASE)}, lambda: clock[0])
    done = acquire.collect_news_social(f, TOKEN, symbol, {"chain": "solana"})
    obs, issues = normalize_phase3a(str(tmp_path))
    return done, obs, issues


def test_gdelt_publication_time_is_not_observed(tmp_path):
    _, obs, _ = run(tmp_path, [GDELT_BODY], [REDDIT_BODY])
    n = [o for o in obs if o.kind == "news"][0]
    assert n.value["publication_time"] is None and n.value["publication_time_state"] == "NOT_OBSERVED"
    assert n.source_ts == int(datetime(2026, 9, 21, 12, tzinfo=timezone.utc).timestamp() * 1000)  # seendate
    assert n.source_ts != n.ingestion_ts and n.ingestion_ts == max(o.ingestion_ts for o in obs if o.kind == "news")
    assert "seendate" in n.value["source_ts_meaning"]
    assert n.value["url"] == "https://news.example/a" and n.value["domain"] == "news.example"
    assert len(n.value["content_sha256"]) == 64 and n.value["referenced_token"] == TOKEN
    assert n.value["reference_verified_state"] == "UNKNOWN"
    assert not any("sentiment" in k for k in n.value)


def test_reddit_three_clocks_kept_separate(tmp_path):
    _, obs, _ = run(tmp_path, [GDELT_BODY], [REDDIT_BODY])
    posts = sorted([o for o in obs if o.kind == "social"], key=lambda o: o.source_ts)
    p = posts[0]
    assert p.value["publication_time"] == 1_789_990_000_000 == p.source_ts
    assert p.ingestion_ts > p.source_ts and p.value["author"] == "someone" and p.venue == "solana"
    assert posts[1].value["author"] is None and posts[1].value["author_state"] == "NOT_OBSERVED"


def test_ingestion_time_never_used_as_publication_time(tmp_path):
    body = json.dumps({"data": {"children": [{"data": {"name": "t3_x", "author": "a", "permalink": "/r/x/1/",
                                                       "title": "t", "selftext": ""}}]}}).encode()
    _, obs, _ = run(tmp_path, [GDELT_BODY], [body])
    p = [o for o in obs if o.kind == "social"][0]
    assert p.value["publication_time"] is None and p.value["publication_time_state"] == "NOT_OBSERVED"
    assert p.source_ts is None and p.source_ts_state == A.NOT_OBSERVED


def test_empty_results_are_not_observed(tmp_path):
    _, obs, _ = run(tmp_path, [b"{}"], [json.dumps({"data": {"children": []}}).encode()])
    assert sorted((o.kind, o.state) for o in obs) == [("news", A.NOT_OBSERVED), ("social", A.NOT_OBSERVED)]


def test_errors_and_plain_text_bodies(tmp_path):
    _, obs, issues = run(tmp_path, [b"Your search contained a keyword that was too short."],
                         [http_error(403), http_error(403)])
    assert sorted((o.kind, o.state) for o in obs) == [("news", A.ERROR), ("social", A.ERROR)]
    assert any("too short" in o.reason for o in obs)


def test_short_symbol_recorded_as_not_applicable(tmp_path):
    done, obs, _ = run(tmp_path, [], [REDDIT_BODY], symbol="AB")
    assert done["gdelt"] == "not_applicable"
    entries = RawStore(tmp_path).entries()
    assert any(e.endpoint == "query_not_applicable" for e in entries)
    assert not [o for o in obs if o.kind == "news"]


def test_news_point_in_time(tmp_path):
    _, obs, _ = run(tmp_path, [GDELT_BODY], [REDDIT_BODY])
    s = EventStore()
    s.extend(obs)
    p = min((o for o in obs if o.kind == "social"), key=lambda o: o.source_ts)
    assert p not in s.view(p.source_ts).observations("social")
    assert p in s.view(p.ingestion_ts).observations("social")


def test_repeat_fetch_deduplicated_by_url(tmp_path):
    _, obs, issues = run(tmp_path, [GDELT_BODY], [REDDIT_BODY])
    clock = [T0 + 10_000]
    net = Net(clock, {"reddit": [REDDIT_BODY]})
    c = HttpClient(ns.REDDIT_BASE, TokenBucket(1e6, 1000, clock=lambda: 0.0, sleep=lambda s: None), {}, max_retries=0,
                   sleep=lambda s: None, opener=net, breaker=CircuitBreaker(50, 1, clock=lambda: 0.0), now_ms=lambda: clock[0])
    f = acquire.Fetcher(RawStore(tmp_path), {ns.REDDIT: c}, lambda: clock[0])
    f.get(ns.REDDIT, "social.reddit", ns.path_reddit(TOKEN), {"chain": "solana", "token": TOKEN, "query": TOKEN})
    again, issues = normalize_phase3a(str(tmp_path))
    assert len([o for o in again if o.kind == "social"]) == 2
    assert sum(i.code == "DUPLICATE_OBSERVATION" for i in issues) == 2
