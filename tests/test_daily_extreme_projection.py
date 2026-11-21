"""Reference mathematics and source contracts for daily-extreme projections.

These tests do not compile or execute MQL5. Broker-server session hours must
be configured and calibrated per symbol before the projections are relied on.
"""
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[1]
ENGINE = ROOT / "MQL5/Include/AutopsyX/DailyExtremeProjectionEngine.mqh"
EA = ROOT / "MQL5/Experts/AutopsyX/AutopsyX_FlipDemon_Extreme.mq5"


def asia_projection(high, low, multiple):
    width = high - low
    if width <= 0:
        raise ValueError("invalid Asia range")
    return high + multiple * width, low - multiple * width


def cbdr_projection(body_high, body_low, multiple):
    width = body_high - body_low
    if width <= 0:
        raise ValueError("invalid CBDR body range")
    return body_high + multiple * width, body_low - multiple * width


def flout_projection(high, low, multiple):
    width = high - low
    if width <= 0:
        raise ValueError("invalid FLOUT range")
    half = width / 2
    midpoint = (high + low) / 2
    return midpoint + multiple * half, midpoint - multiple * half


class ProjectionMathTests(unittest.TestCase):
    def test_asia_range_deviations_are_symmetric(self):
        self.assertEqual(asia_projection(3350, 3320, 1), (3380, 3290))
        self.assertEqual(asia_projection(3350, 3320, 2), (3410, 3260))

    def test_cbdr_uses_body_range(self):
        self.assertEqual(cbdr_projection(3400, 3380, 2), (3440, 3340))

    def test_flout_uses_half_combined_range(self):
        self.assertEqual(flout_projection(3400, 3300, 2), (3450, 3250))

    def test_invalid_ranges_fail_closed(self):
        for fn, args in (
            (asia_projection, (10, 10, 1)),
            (cbdr_projection, (10, 10, 1)),
            (flout_projection, (10, 10, 1)),
        ):
            with self.assertRaises(ValueError):
                fn(*args)


class ProjectionSourceContractTests(unittest.TestCase):
    def test_engine_uses_closed_m1_bars_and_prior_d1_adr(self):
        source = ENGINE.read_text()
        self.assertIn("rates[i].time+60>now", source)
        self.assertIn("CopyRates(m_symbol,PERIOD_D1,1,20,daily)", source)
        self.assertIn("daily[i].high-daily[i].low", source)

    def test_engine_has_all_three_projection_families(self):
        source = ENGINE.read_text()
        for token in ("asiaUpper", "cbdrUpper", "floutUpper",
                      "asiaLower", "cbdrLower", "floutLower"):
            self.assertIn(token, source)

    def test_cbdr_primary_projection_uses_body_range(self):
        source = ENGINE.read_text()
        self.assertIn("m_state.cbdrBodyRange", source)
        self.assertIn("m_state.cbdrWickHigh", source)
        self.assertIn("m_state.cbdrWickLow", source)

    def test_fout_is_not_misrepresented_as_statistical_sigma(self):
        source = ENGINE.read_text()
        self.assertIn("practitioner-defined projection unit", source)
        self.assertIn("not a statistical standard deviation of returns", source)

    def test_projection_engine_is_observational_and_wired(self):
        source = EA.read_text()
        self.assertIn("#include <AutopsyX/DailyExtremeProjectionEngine.mqh>", source)
        self.assertIn("CDailyExtremeProjectionEngine g_dailyExtremeProjection", source)
        self.assertIn("g_dailyExtremeProjection.Init(_Symbol", source)
        self.assertIn("g_dailyExtremeProjection.Update()", source)
        self.assertIn("DAILY EXTREME PROJECTION", source)
        # Projection logic must not mutate order direction or bypass entry gates.
        self.assertNotIn("g_dailyExtremeProjection", source.split("void AxApplyPremiumDiscountScoreBonus", 1)[1].split("void AxApplyAdvancedORBScoreBonus", 1)[0])
