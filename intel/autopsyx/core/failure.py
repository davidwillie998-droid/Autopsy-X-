"""Failure modes the system must recognise and surface, never hide."""
from __future__ import annotations

from enum import Enum


class FailureMode(str, Enum):
    NO_DATA = "NO_DATA"
    STALE_DATA = "STALE_DATA"
    LOW_LIQUIDITY = "LOW_LIQUIDITY"
    HIGH_SLIPPAGE = "HIGH_SLIPPAGE"
    CONFLICTING_DATA = "CONFLICTING_DATA"
    NEWS_UNVERIFIED = "NEWS_UNVERIFIED"
    MANIPULATION_RISK = "MANIPULATION_RISK"
    EXTREME_VOLATILITY = "EXTREME_VOLATILITY"
    EXECUTION_UNAVAILABLE = "EXECUTION_UNAVAILABLE"
    CHAIN_CONGESTION = "CHAIN_CONGESTION"
    API_FAILURE = "API_FAILURE"
    INSUFFICIENT_HISTORY = "INSUFFICIENT_HISTORY"


# Any of these present means the signal engine returns NO_SIGNAL.
BLOCKING = frozenset(
    {
        FailureMode.NO_DATA,
        FailureMode.STALE_DATA,
        FailureMode.CONFLICTING_DATA,
        FailureMode.API_FAILURE,
        FailureMode.EXECUTION_UNAVAILABLE,
        FailureMode.LOW_LIQUIDITY,
    }
)
