"""Premium/discount engine reference and source-contract tests.

These tests validate deterministic range mathematics and source wiring.
They do not execute or compile MQL5.
"""
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / "MQL5/Include/AutopsyX/PremiumDiscountEngine.mqh"
EA = ROOT / "MQL5/Experts/AutopsyX/AutopsyX_FlipDemon_Extreme.mq5"


def classify(price, low, high):
    if high <= low:
        raise ValueError("invalid dealing range")
    position = (price - low) / (high - low)
    zone = "DISCOUNT" if position < 0.5 else "PREMIUM" if position > 0.5 else "EQUILIBRIUM"
    return position, zone


def ote(position):
    return 0.214 <= position <= 0.382, 0.618 <= position <= 0.786


class PremiumDiscountMathTests(unittest.TestCase):
    def test_equilibrium_is_exact_midpoint(self):
        position, zone = classify(150.0, 100.0, 200.0)
        self.assertEqual(position, 0.5)
        self.assertEqual(zone, "EQUILIBRIUM")

    def test_discount_and_premium_halves(self):
        self.assertEqual(classify(125.0, 100.0, 200.0)[1], "DISCOUNT")
        self.assertEqual(classify(175.0, 100.0, 200.0)[1], "PREMIUM")

    def test_price_outside_range_is_not_clamped(self):
        self.assertEqual(classify(210.0, 100.0, 200.0)[0], 1.1)
        self.assertEqual(classify(90.0, 100.0, 200.0)[0], -0.1)

    def test_ote_bands_are_directional_and_separate(self):
        self.assertEqual(ote(0.30), (True, False))
        self.assertEqual(ote(0.70), (False, True))
        self.assertEqual(ote(0.50), (False, False))

    def test_invalid_range_is_rejected(self):
        with self.assertRaises(ValueError):
            classify(100.0, 100.0, 100.0)


class PremiumDiscountSourceContractTests(unittest.TestCase):
    def test_engine_uses_completed_bars_only(self):
        source = SOURCE.read_text()
        self.assertIn("CopyRates(m_symbol,tf,1,m_lookback,rates)", source)
        self.assertIn("iTime(m_symbol,tf,1)", source)
        self.assertIn("IsSwingHigh", source)
        self.assertIn("IsSwingLow", source)

    def test_all_five_timeframes_are_configured(self):
        source = SOURCE.read_text()
        for timeframe in ("PERIOD_W1", "PERIOD_D1", "PERIOD_H4", "PERIOD_H1", "PERIOD_M15"):
            self.assertIn(timeframe, source)

    def test_equilibrium_and_ote_contract(self):
        source = SOURCE.read_text()
        self.assertIn("s.equilibrium=(swingHigh+swingLow)*0.5", source)
        self.assertIn("position>=0.214 && position<=0.382", source)
        self.assertIn("position>=0.618 && position<=0.786", source)

    def test_ea_wires_engine_into_score_after_existing_bonuses(self):
        source = EA.read_text()
        self.assertIn("#include <AutopsyX/PremiumDiscountEngine.mqh>", source)
        self.assertIn("CPremiumDiscountEngine g_premiumDiscount", source)
        self.assertIn("g_premiumDiscount.Init(_Symbol", source)
        self.assertIn("g_premiumDiscount.Update()", source)
        self.assertIn("AxApplyPremiumDiscountScoreBonus(score)", source)
        self.assertLess(source.index("AxApplyAdvancedORBScoreBonus(score)"),
                        source.index("AxApplyPremiumDiscountScoreBonus(score)"))

    def test_location_bonus_respects_w1_d1_directional_authority(self):
        source = EA.read_text()
        marker = "void AxApplyPremiumDiscountScoreBonus(SAxScore &score)"
        self.assertIn(marker, source)
        body = source.split(marker, 1)[1].split("\n  }", 1)[0]
        self.assertIn("g_w1Institutional.AllowsDirection(AX_DIR_BUY)", body)
        self.assertIn("g_d1Institutional.AllowsDirection(AX_DIR_BUY)", body)
        self.assertIn("g_w1Institutional.AllowsDirection(AX_DIR_SELL)", body)
        self.assertIn("g_d1Institutional.AllowsDirection(AX_DIR_SELL)", body)

