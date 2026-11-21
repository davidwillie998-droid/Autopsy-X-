"""Reference math and source contracts for structure-confirmed OB / breaker logic."""
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[1]
ENGINE = ROOT / "MQL5/Include/AutopsyX/OrderBlockEngine.mqh"
EA = ROOT / "MQL5/Experts/AutopsyX/AutopsyX_FlipDemon_Extreme.mq5"


def find_origin(candles, direction, search_bars=8):
    for candle in candles[1:search_bars + 1]:
        opposing = candle["close"] < candle["open"] if direction == "bull" else candle["close"] > candle["open"]
        if opposing:
            if direction == "bull":
                return candle["low"], candle["open"]
            return candle["open"], candle["high"]
    return None


def zone_state(lower, upper, direction, closes):
    state = "ACTIVE"
    for close in closes:
        broken = close < lower if direction == "bull" else close > upper
        if broken:
            return "BREAKER"
    return state


class OrderBlockReferenceTests(unittest.TestCase):
    def test_bullish_ob_uses_last_bearish_candle_body_and_low(self):
        candles = [{"open": 105, "close": 110}, {"open": 104, "close": 101, "low": 99}]
        self.assertEqual(find_origin(candles, "bull"), (99, 104))

    def test_bearish_ob_uses_last_bullish_candle_body_and_high(self):
        candles = [{"open": 95, "close": 90}, {"open": 91, "close": 94, "high": 97}]
        self.assertEqual(find_origin(candles, "bear"), (91, 97))

    def test_no_opposing_origin_returns_none(self):
        candles = [{"open": 100, "close": 105}, {"open": 101, "close": 104}]
        self.assertIsNone(find_origin(candles, "bull"))

    def test_close_through_ob_distal_edge_converts_to_breaker(self):
        self.assertEqual(zone_state(100, 104, "bull", [105, 99]), "BREAKER")
        self.assertEqual(zone_state(100, 104, "bear", [99, 105]), "BREAKER")


class OrderBlockSourceContractTests(unittest.TestCase):
    def test_engine_requires_confirmed_structure_and_displacement(self):
        source = ENGINE.read_text()
        self.assertIn("AX_STRUCT_BOS_BULLISH", source)
        self.assertIn("AX_STRUCT_CHOCH_BEARISH", source)
        self.assertIn("!displacement", source)
        self.assertIn("rates[0].time!=eventTime", source)

    def test_engine_uses_closed_bars_for_creation_and_invalidation(self):
        source = ENGINE.read_text()
        self.assertIn("CopyRates(m_symbol,m_timeframe,1,m_lookbackBars,rates)", source)
        self.assertIn("CopyRates(m_symbol,m_timeframe,1,1,latest)", source)
        self.assertNotIn("CopyRates(m_symbol,m_timeframe,0,", source)

    def test_engine_tracks_retest_expiry_and_breaker_conversion(self):
        source = ENGINE.read_text()
        for token in ("AX_OB_MITIGATED", "AX_OB_BREAKER", "ORDER_BLOCK_EXPIRED",
                      "m_zone.priceInside", "m_zone.retested"):
            self.assertIn(token, source)

    def test_engine_never_sends_or_authorizes_orders(self):
        source = ENGINE.read_text()
        self.assertNotIn("OrderSend(", source)
        self.assertNotIn("CTrade", source)
        self.assertNotIn("PositionOpen(", source)

    def test_ea_wires_structure_event_into_bounded_score(self):
        source = EA.read_text()
        self.assertIn("#include <AutopsyX/OrderBlockEngine.mqh>", source)
        self.assertIn("COrderBlockEngine g_orderBlock", source)
        self.assertIn("g_orderBlock.Update(", source)
        self.assertIn("AxApplyOrderBlockScoreBonus(score)", source)
        self.assertIn("AxClampD(InpOrderBlockScoreWeight,0.0,8.0)", source)


if __name__ == "__main__":
    unittest.main()
