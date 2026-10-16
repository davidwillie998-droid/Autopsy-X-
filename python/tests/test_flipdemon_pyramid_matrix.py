"""Unit tests for the isolated FLIPDEMON pyramid sizing reference model."""
import math
from pathlib import Path
import sys
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "research"))
from flipdemon_pyramid_matrix import (
    PyramidInputs,
    evaluate_add_on,
    schedule_target_lots,
)


def baseline(**overrides):
    values = dict(
        continuation_confirmed=True,
        thesis_valid=True,
        regime_valid=True,
        spread_ok=True,
        broker_state_reconciled=True,
        required_inputs_available=True,
        campaign_is_winning=True,
        current_campaign_stop_risk=100.0,
        campaign_risk_budget=250.0,
        stop_and_cost_risk_per_lot=50.0,
        target_add_lots=2.0,
        current_account_gross_lots=1.0,
        account_gross_lot_cap=5.0,
        current_symbol_lots=1.0,
        symbol_lot_cap=4.0,
        current_directional_lots=1.0,
        directional_lot_cap=3.0,
        equity=10_000.0,
        current_margin=1_000.0,
        free_margin=8_000.0,
        margin_per_lot=500.0,
        max_margin_usage_pct=50.0,
        volume_min=0.01,
        volume_max=100.0,
        volume_step=0.01,
        current_positions=1,
        position_cap=5,
    )
    values.update(overrides)
    return PyramidInputs(**values)


class PyramidMatrixTests(unittest.TestCase):
    def test_returns_safe_target_volume(self):
        decision = evaluate_add_on(baseline())
        self.assertTrue(decision.allowed)
        self.assertAlmostEqual(decision.allowed_lots, 2.0)
        self.assertAlmostEqual(decision.projected_campaign_risk, 200.0)

    def test_larger_target_is_reduced_to_remaining_campaign_risk(self):
        decision = evaluate_add_on(baseline(
            target_add_lots=10.0, account_gross_lot_cap=10.0,
            symbol_lot_cap=10.0, directional_lot_cap=10.0
        ))
        self.assertTrue(decision.allowed)
        self.assertAlmostEqual(decision.allowed_lots, 3.0)
        self.assertTrue(decision.target_was_reduced)
        self.assertLessEqual(decision.projected_campaign_risk, 250.0)

    def test_exhausted_campaign_budget_blocks_addition(self):
        decision = evaluate_add_on(baseline(current_campaign_stop_risk=250.0))
        self.assertFalse(decision.allowed)
        self.assertEqual(decision.allowed_lots, 0.0)
        self.assertIn("CAMPAIGN_RISK_BUDGET_EXHAUSTED", decision.reasons)

    def test_any_missing_hard_gate_fails_closed(self):
        for field, expected in (
            ("continuation_confirmed", "NO_FRESH_CONTINUATION"),
            ("thesis_valid", "THESIS_INVALID"),
            ("regime_valid", "REGIME_NOT_VALIDATED"),
            ("spread_ok", "SPREAD_OR_EXECUTION_COST_BLOCK"),
            ("broker_state_reconciled", "BROKER_STATE_UNRECONCILED"),
            ("required_inputs_available", "REQUIRED_INPUT_MISSING"),
            ("campaign_is_winning", "NO_ADD_TO_LOSING_CAMPAIGN"),
        ):
            with self.subTest(field=field):
                decision = evaluate_add_on(baseline(**{field: False}))
                self.assertFalse(decision.allowed)
                self.assertIn(expected, decision.reasons)

    def test_position_cap_is_a_ceiling_not_a_target(self):
        decision = evaluate_add_on(baseline(current_positions=5, position_cap=5))
        self.assertFalse(decision.allowed)
        self.assertIn("POSITION_CAP_REACHED", decision.reasons)

    def test_account_gross_lot_headroom_limits_size(self):
        decision = evaluate_add_on(baseline(
            target_add_lots=2.0, current_account_gross_lots=4.7,
            account_gross_lot_cap=5.0
        ))
        self.assertTrue(decision.allowed)
        self.assertAlmostEqual(decision.allowed_lots, 0.3)

    def test_symbol_and_direction_caps_are_independent(self):
        symbol_limited = evaluate_add_on(baseline(
            current_symbol_lots=3.8, symbol_lot_cap=4.0
        ))
        self.assertTrue(symbol_limited.allowed)
        self.assertAlmostEqual(symbol_limited.allowed_lots, 0.2)
        direction_limited = evaluate_add_on(baseline(
            current_directional_lots=2.9, directional_lot_cap=3.0
        ))
        self.assertTrue(direction_limited.allowed)
        self.assertAlmostEqual(direction_limited.allowed_lots, 0.1)

    def test_margin_headroom_can_be_tighter_than_risk_budget(self):
        decision = evaluate_add_on(baseline(
            equity=10_000.0, current_margin=4_900.0, free_margin=1_000.0,
            margin_per_lot=500.0, max_margin_usage_pct=50.0, target_add_lots=2.0
        ))
        self.assertTrue(decision.allowed)
        self.assertAlmostEqual(decision.allowed_lots, 0.2)
        self.assertLessEqual(decision.projected_margin_usage_pct, 50.0)

    def test_volume_is_floored_not_rounded_up(self):
        decision = evaluate_add_on(baseline(
            current_account_gross_lots=4.876, account_gross_lot_cap=5.0,
            target_add_lots=2.0
        ))
        self.assertTrue(decision.allowed)
        self.assertAlmostEqual(decision.allowed_lots, 0.12)
        self.assertLessEqual(4.876 + decision.allowed_lots, 5.0)

    def test_minimum_broker_volume_that_exceeds_budget_is_rejected(self):
        decision = evaluate_add_on(baseline(
            current_campaign_stop_risk=249.8, campaign_risk_budget=250.0,
            stop_and_cost_risk_per_lot=50.0, volume_min=0.01, volume_step=0.01
        ))
        self.assertFalse(decision.allowed)
        self.assertEqual(decision.allowed_lots, 0.0)
        self.assertIn("SAFE_VOLUME_BELOW_BROKER_MINIMUM", decision.reasons)

    def test_nan_or_infinite_inputs_fail_closed(self):
        for bad in (math.nan, math.inf, -math.inf):
            with self.subTest(value=bad):
                decision = evaluate_add_on(baseline(stop_and_cost_risk_per_lot=bad))
                self.assertFalse(decision.allowed)
                self.assertEqual(decision.allowed_lots, 0.0)

    def test_invalid_volume_range_fails_closed(self):
        decision = evaluate_add_on(baseline(volume_min=1.0, volume_max=0.5))
        self.assertFalse(decision.allowed)
        self.assertIn("INVALID_VOLUME_RANGE", decision.reasons)

    def test_equity_growth_does_not_expand_fixed_campaign_budget(self):
        low_equity = evaluate_add_on(baseline(
            equity=10_000.0, target_add_lots=10.0,
            account_gross_lot_cap=10.0, symbol_lot_cap=10.0,
            directional_lot_cap=10.0
        ))
        high_equity = evaluate_add_on(baseline(
            equity=20_000.0, target_add_lots=10.0,
            account_gross_lot_cap=10.0, symbol_lot_cap=10.0,
            directional_lot_cap=10.0
        ))
        self.assertAlmostEqual(low_equity.allowed_lots, high_equity.allowed_lots)

    def test_losing_campaign_is_never_averaged_down(self):
        decision = evaluate_add_on(baseline(campaign_is_winning=False))
        self.assertFalse(decision.allowed)
        self.assertIn("NO_ADD_TO_LOSING_CAMPAIGN", decision.reasons)

    def test_increasing_schedule_grows_but_respects_target_ceiling(self):
        self.assertAlmostEqual(schedule_target_lots(1, 0.1, "increasing", 2.0), 0.1)
        self.assertAlmostEqual(schedule_target_lots(2, 0.1, "increasing", 2.0), 0.15)
        self.assertAlmostEqual(schedule_target_lots(20, 0.1, "increasing", 0.5), 0.5)

    def test_equal_and_risk_adaptive_schedules_are_bounded(self):
        self.assertAlmostEqual(schedule_target_lots(5, 0.2, "equal", 1.0), 0.2)
        self.assertAlmostEqual(
            schedule_target_lots(5, 0.2, "risk_adaptive", 1.0, quality_multiplier=0.4),
            0.08,
        )

    def test_schedule_rejects_unbounded_multiplier_and_bad_stage(self):
        with self.assertRaises(ValueError):
            schedule_target_lots(3, 0.1, "increasing", 2.0, increasing_multiplier=3.0)
        with self.assertRaises(ValueError):
            schedule_target_lots(0, 0.1, "equal", 2.0)
        with self.assertRaises(ValueError):
            schedule_target_lots(2, 0.1, "unknown", 2.0)

    def test_boolean_values_are_rejected_as_numeric_inputs(self):
        for field in (
            "current_campaign_stop_risk", "campaign_risk_budget",
            "stop_and_cost_risk_per_lot", "target_add_lots",
            "current_account_gross_lots", "account_gross_lot_cap",
            "current_symbol_lots", "symbol_lot_cap",
            "current_directional_lots", "directional_lot_cap",
            "equity", "current_margin", "free_margin", "margin_per_lot",
            "max_margin_usage_pct", "volume_min", "volume_max", "volume_step",
        ):
            with self.subTest(field=field):
                decision = evaluate_add_on(baseline(**{field: True}))
                self.assertFalse(decision.allowed)
                self.assertEqual(decision.allowed_lots, 0.0)
                self.assertIn("INVALID_NUMERIC_INPUT:" + field, decision.reasons)

    def test_boolean_position_counts_are_rejected(self):
        for field in ("current_positions", "position_cap"):
            with self.subTest(field=field):
                decision = evaluate_add_on(baseline(**{field: True}))
                self.assertFalse(decision.allowed)
                self.assertIn("INVALID_POSITION_CAP", decision.reasons)

    def test_schedule_rejects_boolean_stage_and_numeric_values(self):
        with self.assertRaises(ValueError):
            schedule_target_lots(True, 0.1, "equal", 1.0)
        with self.assertRaises(ValueError):
            schedule_target_lots(1, True, "equal", 1.0)
        with self.assertRaises(ValueError):
            schedule_target_lots(1, 0.1, "equal", True)


if __name__ == "__main__":
    unittest.main()
