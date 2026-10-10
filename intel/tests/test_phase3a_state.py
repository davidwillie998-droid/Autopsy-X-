"""Creator / holder state: explicit availability and hindsight isolation."""
import json

from autopsyx.core.observation import Availability as A
from autopsyx.data.normalize3a import normalize_phase3a
from autopsyx.data.raw import RawStore
from autopsyx.providers.store import EventStore
from autopsyx.research import phase3a_state as st

from phase2_fakes import T_FIX, fixture

TOKEN = json.loads(fixture("gt_token_info.json"))["data"]["attributes"]["address"]
DEV = "9WzDXwBbmkg8ZTbNMqUxvQRAyrZzDsGYdLVL9zYtAWWM"


def info(**attrs):
    doc = json.loads(fixture("gt_token_info.json"))
    doc["data"]["attributes"].update(attrs)
    return json.dumps(doc).encode()


def archive(tmp_path, bodies):
    """bodies: list of (response_ts, body or None)."""
    raw = RawStore(tmp_path)
    for t, b in bodies:
        raw.record(provider="geckoterminal", endpoint="gt.token_info", url="u", request_ts=t - 100,
                   response_ts=None if b is None else t, status=None if b is None else 200, body=b,
                   attempts=1, error=None if b is not None else "HTTP 503", context={"chain": "solana", "token": TOKEN})
    obs, _ = normalize_phase3a(str(tmp_path))
    s = EventStore()
    s.extend(obs)
    return s, obs


def test_null_developer_and_holders_are_not_observed_not_zero(tmp_path):
    _, obs = archive(tmp_path, [(T_FIX, info(developer_address=None, holders=None))])
    by = {o.kind: o for o in obs}
    assert by["creator_state"].state == A.NOT_OBSERVED and by["creator_state"].value == {}
    assert by["holder_state"].state == A.NOT_OBSERVED and by["holder_state"].value == {}


def test_failed_request_is_error_for_both(tmp_path):
    _, obs = archive(tmp_path, [(T_FIX, None)])
    assert sorted((o.kind, o.state) for o in obs) == [("creator_state", A.ERROR), ("holder_state", A.ERROR)]


def test_observed_values_and_states(tmp_path):
    _, obs = archive(tmp_path, [(T_FIX, info(developer_address=DEV, developer_holding_percentage="2.5"))])
    by = {o.kind: o for o in obs}
    c, h = by["creator_state"], by["holder_state"]
    assert c.state == A.OBSERVED and c.value["creator"] == DEV and c.value["creator_pct"] == 0.025
    assert h.state == A.OBSERVED and isinstance(h.value["holder_count"], int)
    assert 0 <= h.value["top10_share"] <= 1 and h.source_ts <= h.ingestion_ts


def test_assessment_states(tmp_path):
    s, _ = archive(tmp_path, [(T_FIX, None), (T_FIX + 60_000, info(developer_address=None)),
                              (T_FIX + 120_000, info(developer_address=DEV))])
    assert st.assess(s.view(T_FIX - 1), "creator_state", TOKEN).state == st.UNKNOWN  # never asked
    assert st.assess(s.view(T_FIX), "creator_state", TOKEN).state == st.UNKNOWN  # only an error
    assert st.assess(s.view(T_FIX + 60_000), "creator_state", TOKEN).state == st.UNAVAILABLE
    k = st.assess(s.view(T_FIX + 120_000), "creator_state", TOKEN)
    assert k.state == st.KNOWN and k.value["creator"] == DEV and k.raw_id
    assert k.value["creator_pct"] is None and k.value["creator_pct_state"] == "NOT_OBSERVED"


def test_historical_assessment_unchanged_by_later_observation(tmp_path):
    """Regression: a later holder observation must not alter an assessment
    made before it; only the hindsight label may say OBSERVED_LATER."""
    s, _ = archive(tmp_path / "a", [(T_FIX, info(holders=None))])
    before = st.assess(s.view(T_FIX + 30_000), "holder_state", TOKEN)
    assert before.state == st.UNAVAILABLE
    later, _ = archive(tmp_path / "b", [(T_FIX + 600_000, fixture("gt_token_info.json"))])
    s.extend(later.view(2**62).observations("holder_state"))
    s.extend(later.view(2**62).observations("creator_state"))
    again = st.assess(s.view(T_FIX + 30_000), "holder_state", TOKEN)
    assert again == before
    assert st.hindsight(s, again) == st.OBSERVED_LATER
    assert st.assess(s.view(T_FIX + 600_000), "holder_state", TOKEN).state == st.KNOWN


def test_hindsight_label_never_reaches_engines():
    import pathlib
    root = pathlib.Path(st.__file__).resolve().parents[1]
    users = [p for p in root.rglob("*.py") if "OBSERVED_LATER" in p.read_text() or "phase3a_state" in p.read_text()]
    rel = sorted(str(p.relative_to(root)) for p in users)
    assert all(r.startswith("research/") for r in rel), rel
