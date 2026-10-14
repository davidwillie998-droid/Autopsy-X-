"""Versioned, path-dependent labels for memecoin momentum research.

This module is deliberately separate from the frozen Phase 3B contract.
It labels historical price paths; it does not alter production signals or
claim that a label is predictive or profitable.
"""
from __future__ import annotations

from dataclasses import dataclass
from math import isfinite
from typing import Iterable


TARGET_CONTRACT_VERSION = "1.0.0"
CANDIDATE_HORIZONS_MS = (5 * 60_000, 15 * 60_000, 60 * 60_000)
CANDIDATE_UPSIDE_THRESHOLDS = (0.05, 0.10, 0.20)


@dataclass(frozen=True)
class PriceBar:
    """One pool-specific OHLC bar, with point-in-time liquidity in USD.

    ts_ms is the bar's open timestamp. Inputs must belong to one token/pool
    episode and be ordered strictly by timestamp. Missing liquidity is None,
    never silently replaced with zero or carried forward.
    """

    ts_ms: int
    open: float
    high: float
    low: float
    close: float
    liquidity_usd: float | None


@dataclass(frozen=True)
class TargetSpec:
    """A preregistered label configuration; costs must be supplied by caller."""

    horizon_ms: int
    upside_threshold_pct: float
    downside_threshold_pct: float
    latency_ms: int
    fee_bps: float
    slippage_bps: float
    max_participation_pct: float
    min_liquidity_usd: float = 0.0

    def __post_init__(self) -> None:
        if self.horizon_ms <= 0:
            raise ValueError("horizon_ms must be positive")
        if self.latency_ms < 0:
            raise ValueError("latency_ms cannot be negative")
        if not 0 < self.upside_threshold_pct < 1:
            raise ValueError("upside_threshold_pct must be between 0 and 1")
        if not 0 < self.downside_threshold_pct < 1:
            raise ValueError("downside_threshold_pct must be between 0 and 1")
        if self.fee_bps < 0 or self.slippage_bps < 0:
            raise ValueError("fee_bps and slippage_bps cannot be negative")
        if not 0 < self.max_participation_pct <= 1:
            raise ValueError("max_participation_pct must be in (0, 1]")
        if self.min_liquidity_usd < 0:
            raise ValueError("min_liquidity_usd cannot be negative")


@dataclass(frozen=True)
class TargetLabel:
    contract_version: str
    token_key: str
    pool_key: str
    decision_ts_ms: int
    entry_ts_ms: int | None
    label_end_ts_ms: int | None
    outcome: str
    horizon_ms: int
    upside_threshold_pct: float
    downside_threshold_pct: float
    entry_notional_usd: float
    observed_mfe_net_pct: float | None
    observed_mae_net_pct: float | None
    realized_net_return_pct: float | None
    bars_held: int
    reason: str


OUTCOMES = frozenset({
    "UPSIDE_FIRST",
    "DOWNSIDE_FIRST",
    "TIMEOUT",
    "AMBIGUOUS_SAME_BAR",
    "ENTRY_UNAVAILABLE",
    "EXIT_UNAVAILABLE",
    "HORIZON_CENSORED",
})


def _validate_bars(bars: list[PriceBar]) -> None:
    previous = None
    for bar in bars:
        values = (bar.open, bar.high, bar.low, bar.close)
        if not all(isfinite(v) and v > 0 for v in values):
            raise ValueError("OHLC prices must be finite and positive")
        if bar.high < max(bar.open, bar.close, bar.low):
            raise ValueError("bar high is inconsistent with OHLC")
        if bar.low > min(bar.open, bar.close, bar.high):
            raise ValueError("bar low is inconsistent with OHLC")
        if bar.liquidity_usd is not None and (
            not isfinite(bar.liquidity_usd) or bar.liquidity_usd < 0
        ):
            raise ValueError("liquidity_usd must be non-negative or None")
        if previous is not None and bar.ts_ms <= previous:
            raise ValueError("bars must have strictly increasing timestamps")
        previous = bar.ts_ms


def _net_return_pct(entry_price: float, exit_price: float, cost_rate: float) -> float:
    """Long return after symmetric proportional fee + slippage assumptions."""
    return ((exit_price * (1.0 - cost_rate)) /
            (entry_price * (1.0 + cost_rate)) - 1.0) * 100.0


def _liquid_enough(bar: PriceBar, notional: float, spec: TargetSpec) -> bool:
    if bar.liquidity_usd is None or bar.liquidity_usd < spec.min_liquidity_usd:
        return False
    return notional <= bar.liquidity_usd * spec.max_participation_pct


def build_target_labels(
    bars: Iterable[PriceBar],
    *,
    token_key: str,
    pool_key: str,
    entry_notional_usd: float,
    spec: TargetSpec,
) -> list[TargetLabel]:
    """Build one label per decision bar using only the future path for its outcome.

    Entry is delayed until the first bar whose open timestamp is at or after
    decision_ts + latency_ms. The profit/loss barrier uses net returns after
    caller-supplied fee and slippage assumptions. If both barriers are crossed
    within one OHLC bar, the outcome is ambiguous and is never counted as a win.
    An incomplete horizon is censored rather than mislabeled as a timeout.

    Call separately for each token/pool episode. Never combine pools just by
    ticker/symbol. Fraud is not inferred by this labeler.
    """
    rows = list(bars)
    _validate_bars(rows)
    if not token_key.strip() or not pool_key.strip():
        raise ValueError("token_key and pool_key are required")
    if not isfinite(entry_notional_usd) or entry_notional_usd <= 0:
        raise ValueError("entry_notional_usd must be finite and positive")

    cost_rate = (spec.fee_bps + spec.slippage_bps) / 10_000.0
    if cost_rate >= 1:
        raise ValueError("combined fee and slippage must be below 100%")
    labels: list[TargetLabel] = []

    for decision_idx, decision in enumerate(rows):
        target_entry_ts = decision.ts_ms + spec.latency_ms
        entry_idx = next(
            (j for j in range(decision_idx + 1, len(rows))
             if rows[j].ts_ms >= target_entry_ts),
            None,
        )
        if entry_idx is None:
            labels.append(TargetLabel(
                TARGET_CONTRACT_VERSION, token_key, pool_key, decision.ts_ms,
                None, None, "ENTRY_UNAVAILABLE", spec.horizon_ms,
                spec.upside_threshold_pct, spec.downside_threshold_pct,
                entry_notional_usd, None, None, None, 0,
                "no bar became available at or after the configured execution latency",
            ))
            continue

        entry = rows[entry_idx]
        if not _liquid_enough(entry, entry_notional_usd, spec):
            labels.append(TargetLabel(
                TARGET_CONTRACT_VERSION, token_key, pool_key, decision.ts_ms,
                entry.ts_ms, entry.ts_ms, "ENTRY_UNAVAILABLE", spec.horizon_ms,
                spec.upside_threshold_pct, spec.downside_threshold_pct,
                entry_notional_usd, None, None, None, 0,
                "entry liquidity is missing or exceeds the configured participation limit",
            ))
            continue

        horizon_end = entry.ts_ms + spec.horizon_ms
        # Bar timestamps denote opens. A bar opening exactly at horizon_end
        # is the expiry price point, not part of the forward barrier path:
        # its high/low/close occur after the label horizon.
        future_rows = rows[entry_idx:]
        path = [b for b in future_rows if b.ts_ms < horizon_end]
        expiry_bar = next((b for b in future_rows if b.ts_ms >= horizon_end), None)
        complete = expiry_bar is not None and expiry_bar.ts_ms == horizon_end
        outcome = "HORIZON_CENSORED"
        reason = "no bar opens exactly at the horizon boundary; expiry price is not observable without interpolation"
        end_ts: int | None = path[-1].ts_ms if path else None
        realized: float | None = None
        held = 0
        observed_path: list[PriceBar] = []

        for held, bar in enumerate(path, start=1):
            observed_path.append(bar)
            up_hit = _net_return_pct(entry.open, bar.high, cost_rate) >= (
                spec.upside_threshold_pct * 100.0
            )
            down_hit = _net_return_pct(entry.open, bar.low, cost_rate) <= (
                -spec.downside_threshold_pct * 100.0
            )
            if not up_hit and not down_hit:
                continue
            end_ts = bar.ts_ms
            if up_hit and down_hit:
                outcome = "AMBIGUOUS_SAME_BAR"
                reason = "both barriers were touched in one OHLC bar; conservative ambiguous label"
            elif not _liquid_enough(bar, entry_notional_usd, spec):
                outcome = "EXIT_UNAVAILABLE"
                reason = "barrier touched but exit liquidity is missing or insufficient"
            elif up_hit:
                outcome = "UPSIDE_FIRST"
                realized = _net_return_pct(entry.open, bar.high, cost_rate)
                reason = "net upside barrier touched before downside barrier"
            else:
                outcome = "DOWNSIDE_FIRST"
                realized = _net_return_pct(entry.open, bar.low, cost_rate)
                reason = "net downside barrier touched before upside barrier"
            break
        else:
            if complete and expiry_bar is not None:
                end_ts = horizon_end
                if not _liquid_enough(expiry_bar, entry_notional_usd, spec):
                    outcome = "EXIT_UNAVAILABLE"
                    reason = "horizon expiry reached without sufficient exit liquidity"
                else:
                    outcome = "TIMEOUT"
                    # The open price at the exact boundary is observable at
                    # expiry; do not use the bar's later close or high/low.
                    realized = _net_return_pct(entry.open, expiry_bar.open, cost_rate)
                    reason = "neither barrier touched before the exact horizon boundary"

        # Path statistics stop at the first barrier touch; later bars must not
        # inflate MFE/MAE for an event that would already have exited.
        mfe = max(_net_return_pct(entry.open, b.high, cost_rate) for b in observed_path)
        mae = min(_net_return_pct(entry.open, b.low, cost_rate) for b in observed_path)

        labels.append(TargetLabel(
            TARGET_CONTRACT_VERSION, token_key, pool_key, decision.ts_ms,
            entry.ts_ms, end_ts, outcome, spec.horizon_ms,
            spec.upside_threshold_pct, spec.downside_threshold_pct,
            entry_notional_usd, mfe, mae, realized, held, reason,
        ))
    return labels


def intervals_overlap(start_a: int, end_a: int, start_b: int, end_b: int) -> bool:
    """Inclusive interval overlap test for label-window purging."""
    if end_a < start_a or end_b < start_b:
        raise ValueError("interval end must not precede its start")
    return start_a <= end_b and start_b <= end_a


def purge_overlapping_training_indices(
    train_intervals: Iterable[tuple[int, int]],
    test_intervals: Iterable[tuple[int, int]],
) -> list[int]:
    """Return train indices whose label intervals do not overlap any test interval."""
    tests = list(test_intervals)
    return [
        i for i, (start, end) in enumerate(train_intervals)
        if not any(intervals_overlap(start, end, ts, te) for ts, te in tests)
    ]
