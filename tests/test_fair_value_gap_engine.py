"""Reference tests and source contracts for the closed-bar FVG retest engine."""
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[1]
ENGINE = ROOT / "MQL5/Include/AutopsyX/FairValueGapEngine.mqh"
EA = ROOT / "MQL5/Experts/AutopsyX/AutopsyX_FlipDemon_Extreme.mq5"


def fvg_zone(older, newer, direction):
    if direction == "bull":
        if newer["low"] <= older["high"]:
            return None
        lower, upper = older["high"], newer["low"]
    else:
        if newer["high"] >= older["low"]:
            return None
        lower, upper = newer["high"], older["low"]
    return lower, upper, (lower + upper) / 2


def fvg_lifecycle(lower, upper, later_bars, direction):
    touched = False
    for bar in later_bars:
        if direction == "bull":
            if bar["close"] < lower or bar["low"] <= lower:
                return False, touched
            touched |= bar["low"] <= upper
        else:
            if bar["close"] > upper or bar["high"] >= upper:
                return False, touched
            touched |= bar["high"] >= lower
    return True, touched


class FairValueGapMathTests(unittest.TestCase):
    def test_bullish_gap_and_consequent_encroachment(self):
        self.assertEqual(fvg_zone({"high": 100}, {"low": 104}, "bull"),
                         (100, 104, 102))

    def test_bearish_gap_and_consequent_encroachment(self):
        self.assertEqual(fvg_zone({"low": 110}, {"high": 106}, "bear"),
                         (106, 110, 108))

    def test_no_gap_is_rejected(self):
        self.assertIsNone(fvg_zone({"high": 100}, {"low": 99}, "bull"))
        self.assertIsNone(fvg_zone({"low": 100}, {"high": 101}, "bear"))

    def test_partial_retrace_marks_zone_touched_but_valid(self):
        valid, touched = fvg_lifecycle(
            100, 104, [{"low": 102, "close": 103, "high": 105}], "bull")
        self.assertTrue(valid)
        self.assertTrue(touched)

    def test_full_fill_invalidates_bullish_gap(self):
        valid, _ = fvg_lifecycle(
            100, 104, [{"low": 99, "close": 101, "high": 105}], "bull")
        self.assertFalse(valid)

    def test_full_fill_invalidates_bearish_gap(self):
        valid, _ = fvg_lifecycle(
            106, 110, [{"low": 105, "close": 108, "high": 111}], "bear")
        self.assertFalse(valid)

    def test_no_retrace_keeps_gap_untouched(self):
        valid, touched = fvg_lifecycle(
            100, 104, [{"low": 105, "close": 106, "high": 108}], "bull")
        self.assertTrue(valid)
        self.assertFalse(touched)


class FairValueGapSourceContractTests(unittest.TestCase):
    def test_engine_uses_closed_bar_history_only_for_formation(self):
        source = ENGINE.read_text()
        self.assertIn("iTime(m_symbol,m_timeframe,1)", source)
        self.assertIn("CopyRates(m_symbol,m_timeframe,1,m_lookbackBars,rates)", source)
        self.assertIn("rates[i].time", source)
        self.assertNotIn("CopyRates(m_symbol,m_timeframe,0,", source)

    def test_engine_checks_gap_size_and_middle_candle_displacement(self):
        source = ENGINE.read_text()
        self.assertIn("gapAtr<m_minGapAtr", source)
        self.assertIn("bodyRatio<m_minBodyRatio", source)
        self.assertIn("PriorAverageRange", source)

    def test_engine_tracks_ce_touch_fill_age_and_live_zone_location(self):
        source = ENGINE.read_text()
        for token in ("consequentEncroachment", "touched", "priceInside",
                      "age>m_maxAgeBars", "rates[j].low<=lower",
                      "rates[j].high>=upper"):
            self.assertIn(token, source)

    def test_engine_is_advisory_and_integrated_into_the_existing_ea(self):
        source = EA.read_text()
        self.assertIn("#include <AutopsyX/FairValueGapEngine.mqh>", source)
        self.assertIn("CFairValueGapEngine g_fvg", source)
        self.assertIn("g_fvg.Init(_Symbol", source)
        self.assertIn("g_fvg.Update(g_md.CurrentMid())", source)
        self.assertIn("AxApplyFvgRetestScoreBonus(score)", source)
        self.assertIn("never an independent entry trigger", source.lower())


class FairValueGapRiskContractTests(unittest.TestCase):
    def test_bonus_is_bounded_and_htf_direction_gated(self):
        source = EA.read_text()
        self.assertIn("AxClampD(InpFvgScoreWeight,0.0,8.0)", source)
        self.assertIn("g_w1Institutional.AllowsDirection(AX_DIR_BUY)", source)
        self.assertIn("g_d1Institutional.AllowsDirection(AX_DIR_SELL)", source)
        self.assertIn("FVG", source)


if __name__ == "__main__":
    unittest.main()
