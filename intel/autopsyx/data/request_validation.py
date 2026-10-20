"""Fail-closed validation for Phase 3C acquisition universe requests."""
from __future__ import annotations

PHASE3C_STRATA = frozenset({"young", "quiet_young", "trending", "established"})


def validate_minimum_strata(strata: object, minimum: int = 20) -> int:
    """Validate requested stratum targets and return their total.

    This validates the requested target only. Selection must separately verify
    that the provider responses actually yield enough distinct token addresses.
    """
    if isinstance(minimum, bool) or not isinstance(minimum, int) or minimum < 1:
        raise ValueError("minimum stratum total must be a positive integer")
    if not isinstance(strata, dict):
        raise ValueError("strata must be a JSON object")
    missing = PHASE3C_STRATA - set(strata)
    extra = set(strata) - PHASE3C_STRATA
    if missing or extra:
        details = []
        if missing:
            details.append("missing: " + ", ".join(sorted(missing)))
        if extra:
            details.append("unexpected: " + ", ".join(sorted(extra)))
        raise ValueError("strata keys invalid (" + "; ".join(details) + ")")
    values = list(strata.values())
    if any(isinstance(v, bool) or not isinstance(v, int) or v < 0 for v in values):
        raise ValueError("each stratum target must be a non-negative integer")
    total = sum(values)
    if total < minimum:
        raise ValueError(
            f"requested universe target is {total}; Phase 3C requires at least "
            f"{minimum} requested tokens across strata; refusing acquisition"
        )
    if total == 0:
        raise ValueError("stratum targets must not all be zero")
    return total
