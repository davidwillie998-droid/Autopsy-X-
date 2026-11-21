"""Reference math and source contracts for the ICT Market Maker Buy/Sell Model.

These tests validate the operational thresholds and source wiring. They do not
execute or compile MQL5, and they do not establish trading expectancy.
"""
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[1]
ENGINE = ROOT / "MQL5/Include/AutopsyX/MarketMakerModelEngine.mqh"
EA = ROOT / "MQL5/Experts/AutopsyX/AutopsyX_FlipDemon_Extreme.mq5"


def terminal_zone_reached(first_curve_up, position_percent, threshold=61.8):
    """MMSM terminates in premium; MMBM uses the mirrored discount zone."""
    return (
        position_percent >= threshold
        if first_curve_up
        else position_percent <= 100.0 - threshold
    )


def returned_to_origin(final_direction, price, origin_low, origin_high):
    if final_direction == "BUY":
        return price >= origin_low
    if final_direction == "SELL":
        return price <= origin_high
    raise ValueError("direction must be BUY or SELL")


def displacement_mss(candle, prior_highs, prior_lows, atr, direction,
                     min_atr=0.75, min_body_ratio=0.55):
    """Closed-bar displacement plus close beyond the prior structure window."""
    candle_range = candle["high"] - candle["low"]
    if candle_range <= 0 or atr <= 0:
        return False
    body_ratio = abs(candle["close"] - candle["open"]) / candle_range
    if body_ratio < min_body_ratio or candle_range < atr * min_atr:
        return False
    close_location = (candle["close"] - candle["low"]) / candle_range
    if direction == "SELL":
        return (
            candle["close"] < candle["open"]
            and candle["close"] < min(prior_lows)
            and close_location <= 0.25
        )
    if direction == "BUY":
        return (
            candle["close"] > candle["open"]
            and candle["close"] > max(prior_highs)
            and close_location >= 0.75
        )
    raise ValueError("direction must be BUY or SELL")


class MarketMakerModelReferenceTests(unittest.TestCase):
    def test_mmsm_requires_premium_terminal_zone(self):
        self.assertTrue(terminal_zone_reached(True, 70.0))
        self.assertFalse(terminal_zone_reached(True, 61.7))

    def test_mmbm_requires_mirrored_discount_terminal_zone(self):
        self.assertTrue(terminal_zone_reached(False, 30.0))
        self.assertFalse(terminal_zone_reached(False, 38.3))

    def test_return_to_origin_uses_near_edge_in_each_direction(self):
        self.assertTrue(returned_to_origin("SELL", 101.0, 95.0, 102.0))
        self.assertFalse(returned_to_origin("SELL", 102.1, 95.0, 102.0))
        self.assertTrue(returned_to_origin("BUY", 99.0, 98.0, 105.0))
        self.assertFalse(returned_to_origin("BUY", 97.9, 98.0, 105.0))

    def test_bearish_reversal_requires_displacement_and_close_below_structure(self):
        candle = {"open": 110, "high": 111, "low": 104, "close": 105}
        self.assertTrue(displacement_mss(candle, [109, 108], [107, 106], 5, "SELL"))
        wick_only = {"open": 110, "high": 111, "low": 103, "close": 108}
        self.assertFalse(displacement_mss(wick_only, [109, 108], [107, 106], 5, "SELL"))

    def test_bullish_reversal_requires_displacement_and_close_above_structure(self):
        candle = {"open": 100, "high": 107, "low": 99, "close": 106}
        self.assertTrue(displacement_mss(candle, [104, 105], [98, 97], 5, "BUY"))
        weak_body = {"open": 100, "high": 107, "low": 99, "close": 103}
        self.assertFalse(displacement_mss(weak_body, [104, 105], [98, 97], 5, "BUY"))


class MarketMakerModelSourceContractTests(unittest.TestCase):
    def test_engine_uses_closed_h4_and_confirmation_bars(self):
        source = ENGINE.read_text(encoding="utf-8")
        self.assertIn("CopyRates(m_symbol,m_curveTimeframe,1,160,curveRates)", source)
        self.assertIn("CopyRates(m_symbol,m_confirmationTimeframe,1,240,confirmRates)", source)
        self.assertIn("iTime(m_symbol,m_curveTimeframe,1)", source)
        self.assertIn("iTime(m_symbol,m_confirmationTimeframe,1)", source)
        self.assertNotIn("CopyRates(m_symbol,m_curveTimeframe,0,", source)
        self.assertNotIn("CopyRates(m_symbol,m_confirmationTimeframe,0,", source)

    def test_engine_requires_liquidity_raid_h4_location_and_m15_reversal(self):
        source = ENGINE.read_text(encoding="utf-8")
        self.assertIn("bool terminalReady=(swept && s.terminalZoneReached)", source)
        self.assertIn("FindReversal(confirmRates,confirmCount,s.curveExtremeTime", source)
        self.assertIn("rates[i].close<priorLow", source)
        self.assertIn("rates[i].close>priorHigh", source)
        self.assertIn("H4_CLOSE_INVALIDATED_TERMINAL_REVERSAL_EXTREME", source)

    def test_pullback_to_origin_is_observed_but_not_a_gate(self):
        source = ENGINE.read_text(encoding="utf-8")
        self.assertIn("originRetestObserved", source)
        self.assertIn("Only count a retest that occurs AFTER the first closed-bar", source)
        self.assertIn("A retest is not required", source)

    def test_engine_never_sends_or_authorizes_orders(self):
        source = ENGINE.read_text(encoding="utf-8")
        for forbidden in ("OrderSend(", "CTrade", "PositionOpen(", "PositionClose("):
            self.assertNotIn(forbidden, source)

    def test_ea_wires_model_but_keeps_score_weight_zero_by_default(self):
        source = EA.read_text(encoding="utf-8")
        self.assertIn("#include <AutopsyX/MarketMakerModelEngine.mqh>", source)
        self.assertIn("CMarketMakerModelEngine g_marketMakerModel", source)
        self.assertIn("g_marketMakerModel.Init(_Symbol,PERIOD_H4", source)
        self.assertIn("g_marketMakerModel.Update(mmxmH4Range)", source)
        self.assertIn("AxApplyMarketMakerModelScoreBonus(score)", source)
        self.assertIn("InpMMXMScoreWeight = 0.0", source)

    def test_optional_score_bonus_is_bounded_and_requires_w1_d1_agreement(self):
        source = EA.read_text(encoding="utf-8")
        marker = "void AxApplyMarketMakerModelScoreBonus(SAxScore &score)"
        self.assertIn(marker, source)
        body = source.split(marker, 1)[1].split("//--- Session ORB", 1)[0]
        self.assertIn("AxClampD(InpMMXMScoreWeight,0.0,8.0)", body)
        self.assertIn("g_w1Institutional.AllowsDirection(mmxm.direction)", body)
        self.assertIn("g_d1Institutional.AllowsDirection(mmxm.direction)", body)
        self.assertIn("mmxm.stage!=AX_MMXM_REVERSAL_CONFIRMED", body)


if __name__ == "__main__":
    unittest.main()
