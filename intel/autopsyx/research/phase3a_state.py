"""Creator and holder state at an assessment moment (evidence layer only).

``assess`` sees only a point-in-time view, so it can only return what was
knowable then:

  KNOWN_AT_ASSESSMENT        an OBSERVED record was ingested at or before as_of
  UNAVAILABLE_FROM_PROVIDER  the provider answered at or before as_of, every
                             answer lacked the fact (NOT_OBSERVED / UNAVAILABLE)
  UNKNOWN_AT_ASSESSMENT      nothing usable by as_of: never asked, or only
                             failed requests (ERROR)

``hindsight`` is the only place OBSERVED_LATER exists. It needs the full
store, takes an assessment that was already made, and labels it; it never
feeds back into ``assess``. Nothing in the engines or the replay imports it.
"""
from __future__ import annotations

from dataclasses import dataclass

from ..core.observation import Availability as A
from ..providers.store import EventStore, PointInTimeView

KNOWN = "KNOWN_AT_ASSESSMENT"
UNKNOWN = "UNKNOWN_AT_ASSESSMENT"
UNAVAILABLE = "UNAVAILABLE_FROM_PROVIDER"
OBSERVED_LATER = "OBSERVED_LATER"
STATE_KINDS = ("creator_state", "holder_state")


@dataclass(frozen=True)
class Assessment:
    kind: str
    token: str
    as_of: int
    state: str
    value: dict  # value of the latest OBSERVED record when KNOWN, else {}
    raw_id: str | None
    ingestion_ts: int | None
    responses: int  # answers visible at as_of, of any state


def assess(view: PointInTimeView, kind: str, token: str) -> Assessment:
    if kind not in STATE_KINDS:
        raise ValueError(kind)
    seen = view.observations(kind, token)
    observed = [o for o in seen if o.state == A.OBSERVED]
    if observed:
        o = max(observed, key=lambda x: (x.ingestion_ts, x.observation_ts))
        return Assessment(kind, token, view.as_of, KNOWN, dict(o.value), o.raw_id, o.ingestion_ts, len(seen))
    answered = [o for o in seen if o.state in (A.NOT_OBSERVED, A.UNAVAILABLE)]
    state = UNAVAILABLE if answered else UNKNOWN
    return Assessment(kind, token, view.as_of, state, {}, None, None, len(seen))


def hindsight(store: EventStore, a: Assessment) -> str:
    """The assessment's state, or OBSERVED_LATER when the fact it lacked was
    ingested after ``a.as_of``. For evidence reporting only."""
    if a.state == KNOWN:
        return KNOWN
    series = store.observations.get(a.kind)
    everything = series.upto(2**62) if series else []
    later = any(o.entity == a.token and o.state == A.OBSERVED and o.ingestion_ts > a.as_of for o in everything)
    return OBSERVED_LATER if later else a.state
