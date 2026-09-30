"""Wallet track records with statistical guards.

One lucky trade does not make "smart money". A wallet is labelled SKILLED only
when the lower bound of its hit-rate confidence interval clears the base rate
of the population it trades in, over enough independent tokens.
"""
from __future__ import annotations

import math
from dataclasses import dataclass
from typing import Sequence


@dataclass(frozen=True)
class ClosedTrade:
    wallet: str
    token_key: str
    entry_ts: int
    exit_ts: int
    pnl_usd: float
    cost_usd: float


@dataclass
class WalletRecord:
    wallet: str
    trades: int
    tokens: int
    wins: int
    hit_rate: float
    hit_rate_lower: float  # Wilson lower bound
    median_return: float
    label: str  # SKILLED | UNPROVEN | INSUFFICIENT_EVIDENCE


def wilson_lower(wins: int, n: int, z: float = 1.96) -> float:
    if n == 0:
        return 0.0
    p = wins / n
    denom = 1 + z * z / n
    centre = p + z * z / (2 * n)
    margin = z * math.sqrt(p * (1 - p) / n + z * z / (4 * n * n))
    return (centre - margin) / denom


def score_wallets(trades: Sequence[ClosedTrade], base_rate: float, min_tokens: int = 20,
                  z: float = 1.96) -> dict[str, WalletRecord]:
    """``base_rate`` is the population hit rate over the same period and token
    universe. Counting per token (not per fill) stops one token's scalps from
    inflating the sample."""
    by_wallet: dict[str, dict[str, float]] = {}
    costs: dict[str, dict[str, float]] = {}
    fills: dict[str, int] = {}
    for t in trades:
        by_wallet.setdefault(t.wallet, {}).setdefault(t.token_key, 0.0)
        by_wallet[t.wallet][t.token_key] += t.pnl_usd
        costs.setdefault(t.wallet, {}).setdefault(t.token_key, 0.0)
        costs[t.wallet][t.token_key] += t.cost_usd
        fills[t.wallet] = fills.get(t.wallet, 0) + 1
    out = {}
    for w, per_tok in by_wallet.items():
        n = len(per_tok)
        wins = sum(1 for v in per_tok.values() if v > 0)
        rets = sorted(per_tok[k] / costs[w][k] for k in per_tok if costs[w][k] > 0)
        med = rets[len(rets) // 2] if rets else 0.0
        lower = wilson_lower(wins, n, z)
        if n < min_tokens:
            label = "INSUFFICIENT_EVIDENCE"
        elif lower > base_rate:
            label = "SKILLED"
        else:
            label = "UNPROVEN"
        out[w] = WalletRecord(w, fills[w], n, wins, wins / n if n else 0.0, lower, med, label)
    return out
