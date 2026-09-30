"""Explicit-availability values.

Every computed quantity in the system is an ``Obs``: a value plus the reason it
can or cannot be trusted. Missing data is never replaced by zero. Arithmetic
helpers propagate the worst status so a single stale input cannot quietly
produce a confident-looking output.
"""
from __future__ import annotations

from dataclasses import dataclass, field
from enum import Enum
from typing import Callable, Iterable


class DataStatus(str, Enum):
    OK = "OK"
    MISSING = "MISSING"
    STALE = "STALE"
    INSUFFICIENT_HISTORY = "INSUFFICIENT_HISTORY"
    UNVERIFIED = "UNVERIFIED"
    CONFLICTING = "CONFLICTING"


# Higher rank = worse. Used when combining inputs.
_STATUS_RANK = {
    DataStatus.OK: 0,
    DataStatus.UNVERIFIED: 1,
    DataStatus.INSUFFICIENT_HISTORY: 2,
    DataStatus.STALE: 3,
    DataStatus.CONFLICTING: 4,
    DataStatus.MISSING: 5,
}


def worst(statuses: Iterable[DataStatus]) -> DataStatus:
    out = DataStatus.OK
    for s in statuses:
        if _STATUS_RANK[s] > _STATUS_RANK[out]:
            out = s
    return out


@dataclass(frozen=True)
class Obs:
    value: float | None
    status: DataStatus = DataStatus.OK
    reason: str = ""
    inputs: tuple[str, ...] = field(default_factory=tuple)

    @property
    def ok(self) -> bool:
        return self.status == DataStatus.OK and self.value is not None

    def get(self) -> float:
        if self.value is None:
            raise ValueError(f"value unavailable: {self.status.value} {self.reason}")
        return self.value

    def or_none(self) -> float | None:
        return self.value if self.ok else None

    def to_dict(self) -> dict:
        return {"value": self.value, "status": self.status.value, "reason": self.reason}


def ok(value: float, *inputs: str) -> Obs:
    return Obs(value=float(value), status=DataStatus.OK, inputs=tuple(inputs))


def missing(reason: str, status: DataStatus = DataStatus.MISSING) -> Obs:
    return Obs(value=None, status=status, reason=reason)


def combine(fn: Callable[..., float], *args: Obs, name: str = "") -> Obs:
    """Apply ``fn`` to the values of ``args``; propagate the worst status.

    If any input has no value the result has no value. Division by zero or
    other math errors surface as MISSING with the error recorded.
    """
    status = worst(a.status for a in args)
    if any(a.value is None for a in args):
        reasons = "; ".join(a.reason for a in args if a.reason)
        return Obs(None, status if status != DataStatus.OK else DataStatus.MISSING, reasons or f"{name}: input missing")
    try:
        v = fn(*(a.value for a in args))
    except (ZeroDivisionError, ValueError, OverflowError) as exc:
        return Obs(None, DataStatus.MISSING, f"{name}: {exc}")
    return Obs(float(v), status, "; ".join(a.reason for a in args if a.reason))
