"""Field validation for provider payloads.

Adapters never repair silently. Anything rejected, dropped, derived or
flagged becomes an ``Issue`` in the normalization report, with the raw_id of
the response it came from.
"""
from __future__ import annotations

import math
import re
from dataclasses import asdict, dataclass
from datetime import datetime, timezone

_B58 = re.compile(r"^[1-9A-HJ-NP-Za-km-z]{32,44}$")
_EVM = re.compile(r"^0x[0-9a-fA-F]{40}$")

EVM_CHAINS = {"ethereum", "eth", "base", "bsc", "arbitrum", "polygon"}
# Earliest plausible timestamp for any record (2015-01-01). Anything earlier is IMPOSSIBLE_TIMESTAMP.
MIN_TS = 1_420_070_400_000


class Code:
    NEGATIVE_PRICE = "NEGATIVE_PRICE"
    NEGATIVE_LIQUIDITY = "NEGATIVE_LIQUIDITY"
    NEGATIVE_VOLUME = "NEGATIVE_VOLUME"
    IMPOSSIBLE_COUNT = "IMPOSSIBLE_COUNT"
    IMPOSSIBLE_OHLC = "IMPOSSIBLE_OHLC"
    IMPOSSIBLE_TIMESTAMP = "IMPOSSIBLE_TIMESTAMP"
    MALFORMED_ADDRESS = "MALFORMED_ADDRESS"
    MALFORMED_RECORD = "MALFORMED_RECORD"
    CHAIN_MISMATCH = "CHAIN_MISMATCH"
    TOKEN_PAIR_MISMATCH = "TOKEN_PAIR_MISMATCH"
    NULL_FIELD = "NULL_FIELD"
    PARTIAL_RESPONSE = "PARTIAL_RESPONSE"
    PROVIDER_ERROR = "PROVIDER_ERROR"
    FORMING_BAR_DROPPED = "FORMING_BAR_DROPPED"
    PAGE_FULL = "PAGE_FULL"
    PAGINATION_GAP = "PAGINATION_GAP"
    DERIVED_FIELD = "DERIVED_FIELD"
    DUPLICATE_OBSERVATION = "DUPLICATE_OBSERVATION"
    OUT_OF_ORDER = "OUT_OF_ORDER"
    CONFLICTING_METADATA = "CONFLICTING_METADATA"
    COVERAGE_GAP = "COVERAGE_GAP"


@dataclass(frozen=True)
class Issue:
    code: str
    raw_id: str | None
    detail: str
    action: str  # dropped_record | dropped_field | flagged | derived | skipped_response

    def to_dict(self) -> dict:
        return asdict(self)


def valid_address(chain: str, addr) -> bool:
    if not isinstance(addr, str):
        return False
    return bool(_EVM.match(addr)) if chain in EVM_CHAINS else bool(_B58.match(addr))


def num(v) -> float | None:
    """Parse a provider number. None, "", non-numeric and non-finite -> None (never 0)."""
    if v is None or isinstance(v, bool):
        return None
    try:
        f = float(v)
    except (TypeError, ValueError):
        return None
    return f if math.isfinite(f) else None


def iso_ms(v) -> int | None:
    if not isinstance(v, str) or not v:
        return None
    try:
        dt = datetime.fromisoformat(v.replace("Z", "+00:00"))
    except ValueError:
        return None
    if dt.tzinfo is None:
        return None  # a timestamp without a zone has no defined meaning here
    return int(dt.astimezone(timezone.utc).timestamp() * 1000)


def check_ts(ts: int | None, response_ts: int, skew_ms: int) -> str | None:
    """Reason string if ts is impossible, else None. An event cannot happen
    after the response that reported it (beyond clock skew)."""
    if ts is None:
        return "missing or unparseable timestamp"
    if ts < MIN_TS:
        return f"timestamp {ts} before 2015"
    if ts > response_ts + skew_ms:
        return f"event time {ts} after response time {response_ts}"
    return None
