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

def validate_phase3c_request(request: object, minimum: int = 20) -> int:
    """Validate the Phase 3C request envelope before any network call."""
    import re

    if not isinstance(request, dict):
        raise ValueError("request must be a JSON object")
    run_id = request.get("run_id")
    if not isinstance(run_id, str) or not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._-]{0,79}", run_id):
        raise ValueError("run_id must be 1-80 safe filename characters (letters, digits, dot, underscore, hyphen)")
    if request.get("network") != "solana":
        raise ValueError("Phase 3C is frozen to network='solana'; refusing scope change")
    seed = request.get("seed")
    if isinstance(seed, bool) or not isinstance(seed, int) or seed < 0:
        raise ValueError("seed must be a non-negative integer")
    selected_minimum = request.get("min_selected_tokens", minimum)
    if (isinstance(selected_minimum, bool) or not isinstance(selected_minimum, int)
            or selected_minimum < minimum):
        raise ValueError(f"min_selected_tokens must be an integer >= {minimum}")
    strata_total = validate_minimum_strata(request.get("strata"), minimum)
    if strata_total < selected_minimum:
        raise ValueError(
            f"requested stratum total {strata_total} is below min_selected_tokens "
            f"{selected_minimum}; refusing acquisition"
        )
    excluded_tokens = request.get("excluded_tokens", [])
    if not isinstance(excluded_tokens, list) or any(
        not isinstance(token, str) or not token for token in excluded_tokens
    ):
        raise ValueError("excluded_tokens must be a list of non-empty token-address strings")
    return strata_total


def distinct_token_count(picked: object) -> int:
    """Count independent token addresses, never pool rows or repeated tokens."""
    if not isinstance(picked, list):
        raise ValueError("picked universe must be a list")
    tokens = {
        row.get("token")
        for row in picked
        if isinstance(row, dict) and isinstance(row.get("token"), str) and row.get("token")
    }
    return len(tokens)
