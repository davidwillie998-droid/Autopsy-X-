"""Reference mathematics and source contracts for NY-clock daily projections.

These tests do not compile or execute MQL5. Live mode derives the current
broker UTC offset. Strategy Tester requires an explicit broker UTC offset.
"""
from pathlib import Path
from datetime import datetime, timezone
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



def first_sunday(year, month):
    first = datetime(year, month, 1)
    return 1 + ((6 - first.weekday()) % 7)


def ny_utc_offset_hours(utc):
    start_day = first_sunday(utc.year, 3) + 7
    end_day = first_sunday(utc.year, 11)
    start = datetime(utc.year, 3, start_day, 7, tzinfo=timezone.utc)
    end = datetime(utc.year, 11, end_day, 6, tzinfo=timezone.utc)
    return -4 if start <= utc < end else -5


class ProjectionMathTests(unittest.TestCase):
    def test_asia_range_deviations_are_symmetric(self):
        self.assertEqual(asia_projection(3350, 3320, 1), (3380, 3290))
        self.assertEqual(asia_projection(3350, 3320, 2), (3410, 3260))

    def test_cbdr_uses_body_range(self):
        self.assertEqual(cbdr_projection(3400, 3380, 2), (3440, 3340))

    def test_flout_uses_half_combined_range(self):
        self.assertEqual(flout_projection(3400, 3300, 2), (3450, 3250))


    def test_new_york_dst_uses_us_transition_instants(self):
        self.assertEqual(ny_utc_offset_hours(datetime(2026, 3, 8, 6, 59, tzinfo=timezone.utc)), -5)
        self.assertEqual(ny_utc_offset_hours(datetime(2026, 3, 8, 7, 0, tzinfo=timezone.utc)), -4)
        self.assertEqual(ny_utc_offset_hours(datetime(2026, 11, 1, 5, 59, tzinfo=timezone.utc)), -4)
        self.assertEqual(ny_utc_offset_hours(datetime(2026, 11, 1, 6, 0, tzinfo=timezone.utc)), -5)

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
        self.assertIn("nearestUpper=%.5f", source)
        self.assertIn("nearestLower=%.5f", source)
        self.assertIn("if(!force && minuteBar==m_lastMinute) return(false);", source)


    def test_sessions_are_new_york_clock_and_asia_uses_prior_evening(self):
        source = ENGINE.read_text()
        ea = EA.read_text()
        self.assertIn("NYUtcOffsetHours", source)
        self.assertIn("NYUtcOffsetForLocal", source)
        self.assertIn("TimeGMT()", source)
        self.assertIn("TimeTradeServer()", source)
        self.assertIn("previousNY.year", source)
        self.assertIn("InpDailyExtremeAsiaStartNewYorkHour = 20", ea)
        self.assertIn("InpDailyExtremeAsiaEndNewYorkHour = 0", ea)
        self.assertIn("InpDailyExtremeCBDRStartNewYorkHour = 14", ea)
        self.assertIn("InpDailyExtremeCBDREndNewYorkHour = 20", ea)
        self.assertIn("TESTER_REQUIRES_EXPLICIT_BROKER_UTC_OFFSET", source)
        self.assertIn("InpDailyExtremeBrokerUtcOffsetMinutes", ea)

    def test_projection_engine_is_observational_and_wired(self):
        source = EA.read_text()
        self.assertIn("#include <AutopsyX/DailyExtremeProjectionEngine.mqh>", source)
        self.assertIn("CDailyExtremeProjectionEngine g_dailyExtremeProjection", source)
        self.assertIn("g_dailyExtremeProjection.Init(_Symbol", source)
        self.assertIn("g_dailyExtremeProjection.Update()", source)
        self.assertIn("NEW YORK IPDA CLOCK", source)
        self.assertIn("g_dailyExtremeProjection.Summary()", source)
        # Projection logic must not mutate order direction or bypass entry gates.
        self.assertNotIn("g_dailyExtremeProjection", source.split("void AxApplyPremiumDiscountScoreBonus", 1)[1].split("void AxApplyAdvancedORBScoreBonus", 1)[0])
