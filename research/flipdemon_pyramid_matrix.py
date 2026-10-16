"""Pure reference model for FLIPDEMON EXTREME's proposed pyramid sizing policy.

No MT5, broker, network, filesystem, or order-execution authority is present.
This is a research oracle for unit tests only. Production MQL5 must independently
calculate and enforce all limits immediately before submission and after fills.
"""
from __future__ import annotations

from dataclasses import dataclass
from decimal import Decimal, ROUND_FLOOR
import math


@dataclass(frozen=True)
class PyramidInputs:
    continuation_confirmed: bool
    thesis_valid: bool
    regime_valid: bool
    spread_ok: bool
    broker_state_reconciled: bool
    required_inputs_available: bool
    campaign_is_winning: bool
    current_campaign_stop_risk: float
    campaign_risk_budget: float
    stop_and_cost_risk_per_lot: float
    target_add_lots: float
    current_account_gross_lots: float
    account_gross_lot_cap: float
    current_symbol_lots: float
    symbol_lot_cap: float
    current_directional_lots: float
    directional_lot_cap: float
    equity: float
    current_margin: float
    free_margin: float
    margin_per_lot: float
    max_margin_usage_pct: float
    volume_min: float
    volume_max: float
    volume_step: float
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


def schedule_target_lots(
    stage_index: int,
    base_lots: float,
    policy: str,
    max_target_lots: float,
    increasing_multiplier: float = 1.5,
    quality_multiplier: float = 1.0,
) -> float:
    """Return a bounded *target*, not an authorized order size.

    stage_index is 1-based for add-ons. Supported policies are equal, increasing,
    and risk_adaptive. Final allowed volume must still pass evaluate_add_on().
    The multiplier is deliberately bounded to prevent exponential runaway.
    """
    values = (base_lots, max_target_lots, increasing_multiplier, quality_multiplier)
    if isinstance(stage_index, bool) or not isinstance(stage_index, int) or stage_index < 1:
        raise ValueError("stage_index must be a positive integer")
    if any(
        isinstance(v, bool)
        or not isinstance(v, (int, float))
        or not math.isfinite(float(v))
        or float(v) <= 0
        for v in values
    ):
        raise ValueError("schedule inputs must be finite positive numbers (booleans are invalid)")
    if increasing_multiplier < 1.0 or increasing_multiplier > 2.0:
        raise ValueError("increasing_multiplier must be between 1.0 and 2.0")
    if quality_multiplier > 1.0:
        raise ValueError("quality_multiplier must not exceed 1.0")
    if policy == "equal":
        target = base_lots
    elif policy == "increasing":
        target = base_lots * (increasing_multiplier ** (stage_index - 1))
    elif policy == "risk_adaptive":
        target = base_lots * quality_multiplier
    else:
        raise ValueError("policy must be equal, increasing, or risk_adaptive")
    return min(target, max_target_lots)


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


def _difference(upper: float, lower: float) -> float:
    """Subtract decimal-valued inputs without binary-float headroom loss."""
    return float(Decimal(str(upper)) - Decimal(str(lower)))


def _floor_to_step(value: float, step: float) -> float:
    """Floor, never round up, to the broker volume step."""
    units = (Decimal(str(value)) / Decimal(str(step))).to_integral_value(
        rounding=ROUND_FLOOR
    )
    return float(units * Decimal(str(step)))


def evaluate_add_on(inputs: PyramidInputs) -> PyramidDecision:
    """Return the largest safe broker-valid add-on, or fail closed.

    Risk budget is fixed for the campaign and supplied by the caller. Floating
    profit or equity growth never expands it. Risk-per-lot must include a
    conservative allowance for spread, commission and slippage.
    """
    reasons = [
        code for field, code in _GATE_FIELDS
        if getattr(inputs, field) is not True
    ]

    if (isinstance(inputs.current_positions, bool)
            or isinstance(inputs.position_cap, bool)
            or not isinstance(inputs.current_positions, int)
            or not isinstance(inputs.position_cap, int)
            or inputs.current_positions < 0 or inputs.position_cap < 1):
        reasons.append("INVALID_POSITION_CAP")
    elif inputs.current_positions >= inputs.position_cap:
        reasons.append("POSITION_CAP_REACHED")

    for field in _NUMERIC_FIELDS:
        value = getattr(inputs, field)
        if (isinstance(value, bool)
                or not isinstance(value, (int, float))
                or not _finite_nonnegative(float(value))):
            reasons.append("INVALID_NUMERIC_INPUT:" + field)

    for field in (
        "campaign_risk_budget", "stop_and_cost_risk_per_lot",
        "target_add_lots", "account_gross_lot_cap", "symbol_lot_cap",
        "directional_lot_cap", "equity", "margin_per_lot",
        "volume_min", "volume_max", "volume_step", "max_margin_usage_pct",
    ):
        value = getattr(inputs, field)
        if (not isinstance(value, bool)
                and isinstance(value, (int, float))
                and math.isfinite(float(value))
                and value <= 0):
            reasons.append("NONPOSITIVE_REQUIRED_INPUT:" + field)

    if inputs.volume_max < inputs.volume_min:
        reasons.append("INVALID_VOLUME_RANGE")
    if inputs.max_margin_usage_pct > 100.0:
        reasons.append("INVALID_MARGIN_USAGE_CAP")
    if reasons:
        return PyramidDecision(False, 0.0, tuple(dict.fromkeys(reasons)), None, None, False)

    risk_remaining = _difference(
        inputs.campaign_risk_budget, inputs.current_campaign_stop_risk
    )
    current_margin_pct = inputs.current_margin / inputs.equity * 100.0
    if risk_remaining <= 0.0:
        return PyramidDecision(
            False, 0.0, ("CAMPAIGN_RISK_BUDGET_EXHAUSTED",),
            inputs.current_campaign_stop_risk, current_margin_pct, False
        )

    risk_limited_lots = risk_remaining / inputs.stop_and_cost_risk_per_lot
    account_headroom = _difference(
        inputs.account_gross_lot_cap, inputs.current_account_gross_lots
    )
    symbol_headroom = _difference(inputs.symbol_lot_cap, inputs.current_symbol_lots)
    direction_headroom = _difference(
        inputs.directional_lot_cap, inputs.current_directional_lots
    )
    margin_cap_money = inputs.equity * inputs.max_margin_usage_pct / 100.0
    margin_headroom_money = min(
        inputs.free_margin, _difference(margin_cap_money, inputs.current_margin)
    )
    margin_limited_lots = margin_headroom_money / inputs.margin_per_lot

    raw_lots = min(
        inputs.target_add_lots, inputs.volume_max, risk_limited_lots,
        account_headroom, symbol_headroom, direction_headroom, margin_limited_lots,
    )
    lots = _floor_to_step(max(0.0, raw_lots), inputs.volume_step)

    if lots < inputs.volume_min:
        return PyramidDecision(
            False, 0.0, ("SAFE_VOLUME_BELOW_BROKER_MINIMUM",),
            inputs.current_campaign_stop_risk, current_margin_pct, False,
        )

    projected_risk = (
        inputs.current_campaign_stop_risk + lots * inputs.stop_and_cost_risk_per_lot
    )
    projected_margin = (
        (inputs.current_margin + lots * inputs.margin_per_lot) / inputs.equity * 100.0
    )

    # Recheck every hard constraint after volume normalization.
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

    reason = "SAFE_ADD_ON" if lots >= inputs.target_add_lots else (
        "SAFE_SIZE_REDUCED_TO_RISK_CAPACITY"
    )
    return PyramidDecision(
        True, lots, (reason,), projected_risk, projected_margin,
        lots + 1e-8 < inputs.target_add_lots,
    )
