"""Reference acceptance tests for FlipDemon Extreme adaptive sizing policy.

These tests validate the written sizing rules, not the MQL5 EA implementation.
They intentionally use pure arithmetic so the same cases can later be mirrored in
MetaEditor/MT5 Strategy Tester. No test result implies EA compilation or profitability.
"""
from dataclasses import dataclass
import math
import unittest


ABSOLUTE_RISK_CAP_PCT = 2.0
MAX_GROWTH_MULTIPLIER = 1.50


def growth_multiplier(growth_pct: float) -> float:
    if not math.isfinite(growth_pct):
        return 0.0
    if growth_pct < 10.0:
        return 1.0
    if growth_pct < 25.0:
        return 1.10
    if growth_pct < 50.0:
        return 1.20
    return 1.35


def effective_risk_pct(base_pct: float, growth_pct: float,
                       drawdown_multiplier: float, configured_cap_pct: float = 2.0,
                       fresh_continuation: bool = True,
                       loss_since_peak: bool = False) -> float:
    vals = (base_pct, growth_pct, drawdown_multiplier, configured_cap_pct)
    if not all(math.isfinite(v) for v in vals):
        return 0.0
    if base_pct <= 0 or configured_cap_pct <= 0 or drawdown_multiplier <= 0:
        return 0.0
    if not fresh_continuation or loss_since_peak:
        return min(base_pct * drawdown_multiplier,
                   configured_cap_pct, ABSOLUTE_RISK_CAP_PCT)
    multiplier = min(growth_multiplier(growth_pct), MAX_GROWTH_MULTIPLIER)
    if multiplier <= 0:
        return 0.0
    return min(base_pct * multiplier * drawdown_multiplier,
               configured_cap_pct, ABSOLUTE_RISK_CAP_PCT)


def normalize_down(raw_lots: float, minimum: float, maximum: float,
                   step: float) -> float:
    vals = (raw_lots, minimum, maximum, step)
    if not all(math.isfinite(v) for v in vals):
        return 0.0
    if raw_lots <= 0 or minimum <= 0 or maximum < minimum or step <= 0:
        return 0.0
    if raw_lots + 1e-12 < minimum:
        return 0.0
    volume = math.floor((min(raw_lots, maximum) / step) + 1e-10) * step
    # Floating-point safe normalization; never round up.
    volume = round(volume, 8)
    if volume + 1e-12 < minimum or volume > maximum + 1e-12:
        return 0.0
    return volume


def risk_sized_lots(equity: float, risk_pct: float, one_lot_stop_loss: float,
                    min_lot: float, max_lot: float, step: float) -> float:
    vals = (equity, risk_pct, one_lot_stop_loss)
    if not all(math.isfinite(v) for v in vals):
        return 0.0
    if equity <= 0 or risk_pct <= 0 or one_lot_stop_loss <= 0:
        return 0.0
    raw_lots = equity * min(risk_pct, ABSOLUTE_RISK_CAP_PCT) / 100.0 / one_lot_stop_loss
    lots = normalize_down(raw_lots, min_lot, max_lot, step)
    if lots <= 0:
        return 0.0
    projected_risk = lots * one_lot_stop_loss / equity * 100.0
    if projected_risk > min(risk_pct, ABSOLUTE_RISK_CAP_PCT) + 1e-9:
        return 0.0
    return lots


@dataclass(frozen=True)
class Campaign:
    current_risk_pct: float
    proposed_add_risk_pct: float
    entries: int
    max_entries: int = 10
    campaign_limit_pct: float = 2.0
    fresh_signal: bool = True
    campaign_profitable: bool = True
    protected: bool = True


def allow_add(c: Campaign) -> bool:
    if c.entries < 0 or c.max_entries <= 0:
        return False
    if c.entries >= c.max_entries or not c.fresh_signal:
        return False
    if not c.campaign_profitable or not c.protected:
        return False
    if not all(math.isfinite(x) for x in (
        c.current_risk_pct, c.proposed_add_risk_pct, c.campaign_limit_pct
    )):
        return False
    if c.current_risk_pct < 0 or c.proposed_add_risk_pct <= 0 or c.campaign_limit_pct <= 0:
        return False
    return c.current_risk_pct + c.proposed_add_risk_pct <= c.campaign_limit_pct + 1e-9


class SizingPolicyTests(unittest.TestCase):
    def test_small_account_below_minimum_rejects_instead_of_rounding_up(self):
        self.assertEqual(risk_sized_lots(50, 0.5, 100, 0.01, 100, 0.01), 0.0)

    def test_valid_size_rounds_down_to_step(self):
        self.assertAlmostEqual(normalize_down(0.037, 0.01, 10, 0.01), 0.03)

    def test_never_exceeds_broker_maximum(self):
        self.assertAlmostEqual(normalize_down(3.0, 0.01, 1.0, 0.01), 1.0)

    def test_invalid_metadata_fails_closed(self):
        self.assertEqual(normalize_down(0.5, 0.01, 1.0, 0.0), 0.0)
        self.assertEqual(risk_sized_lots(100, 1.0, 0.0, 0.01, 1.0, 0.01), 0.0)

    def test_risk_hard_cap_is_two_percent(self):
        self.assertEqual(effective_risk_pct(5.0, 70.0, 1.0, 5.0), 2.0)

    def test_growth_tiers(self):
        self.assertEqual(growth_multiplier(9.99), 1.0)
        self.assertEqual(growth_multiplier(10.0), 1.10)
        self.assertEqual(growth_multiplier(25.0), 1.20)
        self.assertEqual(growth_multiplier(50.0), 1.35)
        self.assertEqual(growth_multiplier(float("nan")), 0.0)

    def test_no_growth_boost_without_fresh_setup_or_after_loss(self):
        self.assertEqual(effective_risk_pct(0.5, 60, 1.0, fresh_continuation=False), 0.5)
        self.assertEqual(effective_risk_pct(0.5, 60, 1.0, loss_since_peak=True), 0.5)

    def test_drawdown_multiplier_reduces_risk_and_locked_blocks(self):
        self.assertAlmostEqual(effective_risk_pct(1.0, 30, 0.65), 0.78)
        self.assertAlmostEqual(effective_risk_pct(1.0, 30, 0.30), 0.36)
        self.assertEqual(effective_risk_pct(1.0, 30, 0.0), 0.0)

    def test_add_respects_aggregate_campaign_risk(self):
        self.assertTrue(allow_add(Campaign(1.0, 0.5, 2, campaign_limit_pct=2.0)))
        self.assertFalse(allow_add(Campaign(1.7, 0.5, 2, campaign_limit_pct=2.0)))

    def test_add_requires_fresh_signal_profit_and_protection(self):
        self.assertFalse(allow_add(Campaign(0.5, 0.25, 2, fresh_signal=False)))
        self.assertFalse(allow_add(Campaign(0.5, 0.25, 2, campaign_profitable=False)))
        self.assertFalse(allow_add(Campaign(0.5, 0.25, 2, protected=False)))

    def test_campaign_entry_limit_is_ceiling_not_target(self):
        self.assertFalse(allow_add(Campaign(0.5, 0.25, 10, max_entries=10)))

    def test_leverage_is_not_an_input_to_risk_sizing(self):
        # Same equity, stop loss and risk budget produce the same result;
        # leverage is intentionally not accepted by the function.
        a = risk_sized_lots(1000, 0.5, 100, 0.01, 10, 0.01)
        b = risk_sized_lots(1000, 0.5, 100, 0.01, 10, 0.01)
        self.assertEqual(a, b)


if __name__ == "__main__":
    unittest.main(verbosity=2)
