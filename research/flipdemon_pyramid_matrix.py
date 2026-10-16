"""Pure reference model for FLIPDEMON EXTREME's proposed pyramid sizing policy.

This module has no MT5, broker, network, filesystem, or order-execution authority.
It is a research oracle for unit tests only. Production MQL5 must independently
calculate and enforce all limits immediately before submission and after fills.
"""
from __future__ import annotations

from dataclasses import dataclass
from decimal import Decimal, ROUND_FLOOR
import math


@dataclass(frozen=True)
class PyramidInputs:
    # Hard eligibility gates. Every gate must be true to consider an add-on.
    continuation_confirmed: bool
    thesis_valid: bool
    regime_valid: bool
    spread_ok: bool
    broker_state_reconciled: bool
    required_inputs_available: bool
    campaign_is_winning: bool

    # Campaign risk and volume inputs, all monetary values in account currency.
    current_campaign_stop_risk: float
    campaign_risk_budget: float
    stop_and_cost_risk_per_lot: float
    target_add_lots: float

    # Exposure ceilings include the proposed add-on.
    current_account_gross_lots: float
    account_gross_lot_cap: float
    current_symbol_lots: float
    symbol_lot_cap: float
    current_directional_lots: float
    directional_lot_cap: float

    # Margin inputs. margin_per_lot must be a conservative broker-aware estimate.
    equity: float
    current_margin: float
    free_margin: float
    margin_per_lot: float
    max_margin_usage_pct: float

    # Broker volume constraints.
    volume_min: float
    volume_max: float
    volume_step: float

    # Position-count ceiling is a ceiling, never a target to fill.
    current_positions: int
    position_cap: int


@dataclass(frozen=True)
class PyramidDecision:
    allowed: bool
    allowed_lots: float
    reasons: tuple[str, ...]
    projected_campaign_risk: float | None
    projected_margin_usage_pct: float | None
    target_was_reduced: bool


_GATE_FIELDS = (
    ("continuation_confirmed", "NO_FRESH_CONTINUATION"),
    ("thesis_valid", "THESIS_INVALID"),
    ("regime_valid", "REGIME_NOT_VALIDATED"),
    ("spread_ok", "SPREAD_OR_EXECUTION_COST_BLOCK"),
    ("broker_state_reconciled", "BROKER_STATE_UNRECONCILED"),
    ("required_inputs_available", "REQUIRED_INPUT_MISSING"),
    ("campaign_is_winning", "NO_ADD_TO_LOSING_CAMPAIGN"),
)

_NUMERIC_FIELDS = (
    "current_campaign_stop_risk", "campaign_risk_budget",
    "stop_and_cost_risk_per_lot", "target_add_lots",
    "current_account_gross_lots", "account_gross_lot_cap",
    "current_symbol_lots", "symbol_lot_cap",
    "current_directional_lots", "directional_lot_cap",
    "equity", "current_margin", "free_margin", "margin_per_lot",
    "max_margin_usage_pct", "volume_min", "volume_max", "volume_step",
)


def _finite_nonnegative(value: float) -> bool:
    return math.isfinite(value) and value >= 0.0


def _floor_to_step(value: float, step: float) -> float:
    """Floor, never round up, to the broker volume step using decimal arithmetic."""
    units = (Decimal(str(value)) / Decimal(str(step))).to_integral_value(
        rounding=ROUND_FLOOR
    )
    result = units * Decimal(str(step))
    return float(result)


def evaluate_add_on(inputs: PyramidInputs) -> PyramidDecision:
    """Return the largest safe broker-valid add-on, or fail closed.

    Risk budget is a fixed campaign budget supplied by the caller. This function
    never expands it when floating profit or equity rises. Risk-per-lot must
    already include a conservative allowance for spread, commission and slippage.
    """
    reasons = [
        code for field, code in _GATE_FIELDS
        if getattr(inputs, field) is not True
    ]

    if inputs.current_positions < 0 or inputs.position_cap < 1:
        reasons.append("INVALID_POSITION_CAP")
    elif inputs.current_positions >= inputs.position_cap:
        reasons.append("POSITION_CAP_REACHED")

    for field in _NUMERIC_FIELDS:
        value = getattr(inputs, field)
        if not isinstance(value, (int, float)) or not _finite_nonnegative(float(value)):
            reasons.append("INVALID_NUMERIC_INPUT:" + field)

    # Values that must be strictly positive to calculate a safe volume.
    for field in (
        "campaign_risk_budget", "stop_and_cost_risk_per_lot",
        "target_add_lots", "account_gross_lot_cap", "symbol_lot_cap",
        "directional_lot_cap", "equity", "margin_per_lot",
        "volume_min", "volume_max", "volume_step", "max_margin_usage_pct",
    ):
        value = getattr(inputs, field)
        if isinstance(value, (int, float)) and math.isfinite(float(value)) and value <= 0:
            reasons.append("NONPOSITIVE_REQUIRED_INPUT:" + field)

    if inputs.volume_max < inputs.volume_min:
        reasons.append("INVALID_VOLUME_RANGE")
    if inputs.max_margin_usage_pct > 100.0:
        reasons.append("INVALID_MARGIN_USAGE_CAP")
    if reasons:
        return PyramidDecision(False, 0.0, tuple(dict.fromkeys(reasons)), None, None, False)

    risk_remaining = inputs.campaign_risk_budget - inputs.current_campaign_stop_risk
    if risk_remaining <= 0.0:
        return PyramidDecision(False, 0.0, ("CAMPAIGN_RISK_BUDGET_EXHAUSTED",), 
                               inputs.current_campaign_stop_risk, 
                               inputs.current_margin / inputs.equity * 100.0, False)

    risk_limited_lots = risk_remaining / inputs.stop_and_cost_risk_per_lot
    account_headroom = inputs.account_gross_lot_cap - inputs.current_account_gross_lots
    symbol_headroom = inputs.symbol_lot_cap - inputs.current_symbol_lots
    direction_headroom = inputs.directional_lot_cap - inputs.current_directional_lots
    margin_cap_money = inputs.equity * inputs.max_margin_usage_pct / 100.0
    margin_headroom_money = min(
        inputs.free_margin,
        margin_cap_money - inputs.current_margin,
    )
    margin_limited_lots = margin_headroom_money / inputs.margin_per_lot

    raw_lots = min(
        inputs.target_add_lots,
        inputs.volume_max,
        risk_limited_lots,
        account_headroom,
        symbol_headroom,
        direction_headroom,
        margin_limited_lots,
    )
    lots = _floor_to_step(max(0.0, raw_lots), inputs.volume_step)

    if lots < inputs.volume_min:
        return PyramidDecision(
            False, 0.0, ("SAFE_VOLUME_BELOW_BROKER_MINIMUM",),
            inputs.current_campaign_stop_risk,
            inputs.current_margin / inputs.equity * 100.0,
            False,
        )

    projected_risk = (
        inputs.current_campaign_stop_risk + lots * inputs.stop_and_cost_risk_per_lot
    )
    projected_margin = (
        (inputs.current_margin + lots * inputs.margin_per_lot) / inputs.equity * 100.0
    )

    # Independent post-normalization invariant checks. Any arithmetic or rounding
    # surprise blocks the order instead of weakening a limit.
    if projected_risk > inputs.campaign_risk_budget + 1e-8:
        return PyramidDecision(False, 0.0, ("POST_NORMALIZATION_RISK_BREACH",),
                               projected_risk, projected_margin, False)
    if inputs.current_account_gross_lots + lots > inputs.account_gross_lot_cap + 1e-8:
        return PyramidDecision(False, 0.0, ("POST_NORMALIZATION_ACCOUNT_EXPOSURE_BREACH",),
                               projected_risk, projected_margin, False)
    if inputs.current_symbol_lots + lots > inputs.symbol_lot_cap + 1e-8:
        return PyramidDecision(False, 0.0, ("POST_NORMALIZATION_SYMBOL_EXPOSURE_BREACH",),
                               projected_risk, projected_margin, False)
    if inputs.current_directional_lots + lots > inputs.directional_lot_cap + 1e-8:
        return PyramidDecision(False, 0.0, ("POST_NORMALIZATION_DIRECTIONAL_EXPOSURE_BREACH",),
                               projected_risk, projected_margin, False)
    if projected_margin > inputs.max_margin_usage_pct + 1e-8:
        return PyramidDecision(False, 0.0, ("POST_NORMALIZATION_MARGIN_BREACH",),
                               projected_risk, projected_margin, False)
    if lots * inputs.margin_per_lot > inputs.free_margin + 1e-8:
        return PyramidDecision(False, 0.0, ("POST_NORMALIZATION_FREE_MARGIN_BREACH",),
                               projected_risk, projected_margin, False)

    reasons_out = ("SAFE_ADD_ON",) if lots >= inputs.target_add_lots else (
        "SAFE_SIZE_REDUCED_TO_RISK_CAPACITY",
    )
    return PyramidDecision(
        True, lots, reasons_out, projected_risk, projected_margin,
        lots + 1e-8 < inputs.target_add_lots,
    )
