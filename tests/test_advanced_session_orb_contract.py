"""Static contracts for the Advanced multi-session ORB evidence engine."""
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[1]
EA = (ROOT / "MQL5/Experts/AutopsyX/AutopsyX_FlipDemon_Extreme.mq5").read_text(
    encoding="utf-8-sig"
)
ORB = (ROOT / "MQL5/Include/AutopsyX/AdvancedSessionORBEngine.mqh").read_text(
    encoding="utf-8-sig"
)


class AdvancedSessionORBContractTests(unittest.TestCase):
    def test_engine_is_included_and_instantiated(self):
        self.assertIn('#include <AutopsyX/AdvancedSessionORBEngine.mqh>', EA)
        self.assertIn("CAdvancedSessionORBEngine g_advancedSessionOrb;", EA)

    def test_session_configuration_is_explicitly_broker_server_time(self):
        self.assertIn("InpORBAsiaServerHour", EA)
        self.assertIn("InpORBLondonServerHour", EA)
        self.assertIn("InpORBNewYorkServerHour", EA)
        self.assertIn("broker server time", EA.lower())

    def test_opening_range_uses_completed_m1_anchor_window(self):
        self.assertIn("CopyRates(symbol,PERIOD_M1,from,to,bars)", ORB)
        self.assertIn("m_rangeMinutes-2", ORB)
        self.assertIn("rangeHigh=high", ORB)
        self.assertIn("rangeLow=low", ORB)

    def test_breakout_and_retest_use_closed_confirmation_bars(self):
        self.assertIn("CopyRates(symbol,m_breakoutTimeframe,1,2,recent)", ORB)
        self.assertIn("latest.close>high+buffer", ORB)
        self.assertIn("latest.close<low-buffer", ORB)
        self.assertIn("AX_ORB_RETEST_BUY", ORB)
        self.assertIn("AX_ORB_RETEST_SELL", ORB)

    def test_breakout_quality_requires_body_close_and_relative_volume(self):
        self.assertIn("CandleBodyRatio(latest)", ORB)
        self.assertIn("CandleCloseLocation(latest)", ORB)
        self.assertIn("m_minVolumeRatio", ORB)
        self.assertIn("CopyRates(symbol,m_breakoutTimeframe,2,20,history)", ORB)

    def test_failed_breakout_is_recorded_not_traded_as_an_automatic_reversal(self):
        self.assertIn("AX_ORB_FAILED_BULLISH", ORB)
        self.assertIn("AX_ORB_FAILED_BEARISH", ORB)
        self.assertIn("never auto-traded in reverse", ORB)

    def test_conflicting_session_directions_produce_no_direction(self):
        self.assertIn("CONFLICTING_SESSION_BREAKOUTS", ORB)
        self.assertIn("m_reading.direction=AX_DIR_NONE", ORB)

    def test_each_session_range_and_previous_d1_w1_levels_are_exposed(self):
        self.assertIn("bool GetSessionAt", ORB)
        self.assertIn("iHigh(symbol,PERIOD_D1,1)", ORB)
        self.assertIn("iLow(symbol,PERIOD_D1,1)", ORB)
        self.assertIn("iHigh(symbol,PERIOD_W1,1)", ORB)
        self.assertIn("iLow(symbol,PERIOD_W1,1)", ORB)
        self.assertIn("nearestResistance", ORB)
        self.assertIn("nearestSupport", ORB)
        self.assertIn("InpORBMinRoomToHTFLevelPoints", EA)

    def test_orb_is_advisory_and_cannot_override_w1_d1_authority(self):
        self.assertIn("AxApplyAdvancedORBScoreBonus(score)", EA)
        self.assertIn("g_w1Institutional.AllowsDirection(orb.direction)", EA)
        self.assertIn("g_d1Institutional.AllowsDirection(orb.direction)", EA)
        self.assertIn("InpORBScoreBonus", EA)

    def test_orb_defaults_off_and_does_not_send_orders(self):
        self.assertIn("InpEnableAdvancedSessionORB = false", EA)
        for forbidden in ("OrderSend(", "PositionOpen(", "Buy(", "Sell("):
            self.assertNotIn(forbidden, ORB)

    def test_data_is_not_reported_available_without_a_completed_range(self):
        self.assertIn("m_reading.available=false", ORB)
        self.assertIn("m_reading.available=true", ORB)
        self.assertIn("NO_COMPLETED_OPENING_RANGE", ORB)

    def test_history_reads_are_throttled_to_new_closed_breakout_bars(self):
        self.assertIn("iTime(symbol,m_breakoutTimeframe,1)", ORB)
        self.assertIn("latestClosedBar==m_lastUpdateBar", ORB)
        self.assertIn("m_lastUpdateBar=recent[0].time", ORB)


    def test_chart_diagnostics_draw_overlapping_session_ranges_and_htf_levels(self):
        self.assertIn("OBJ_RECTANGLE", ORB)
        self.assertIn('EnsureRectangle(key+"_RANGE"', ORB)
        self.assertIn('EnsureTrend(key+"_HIGH"', ORB)
        self.assertIn('EnsureTrend(key+"_LOW"', ORB)
        self.assertIn('"PDH"', ORB)
        self.assertIn('"PDL"', ORB)
        self.assertIn('"PWH"', ORB)
        self.assertIn('"PWL"', ORB)
        self.assertIn("ChartRedraw(m_chartId)", ORB)

    def test_breakout_retest_and_failed_breakout_markers_use_signal_bar(self):
        self.assertIn("datetime signalBar", ORB)
        self.assertIn("OBJ_ARROW", ORB)
        self.assertIn("FAILED", ORB)
        self.assertIn("session.signalBar", ORB)
        self.assertIn("m_sessions[index].signalBar=latest.time", ORB)

    def test_chart_object_namespace_is_scoped_and_cleaned_on_deinit(self):
        self.assertIn('m_objectPrefix="AXORB_"', ORB)
        self.assertIn("ObjectsDeleteAll(m_chartId,m_objectPrefix)", ORB)
        self.assertIn("g_advancedSessionOrb.SetChartIdentity(_Symbol,InpMagicNumber)", EA)
        self.assertIn("g_advancedSessionOrb.Cleanup()", EA)
        self.assertIn("void OnDeinit", EA)

    def test_chart_diagnostics_are_visual_only(self):
        self.assertIn("void DrawDiagnostics", ORB)
        self.assertIn("DrawDiagnostics(symbol)", ORB)
        for forbidden in ("OrderSend(", "PositionOpen(", "Buy(", "Sell("):
            self.assertNotIn(forbidden, ORB)

    def test_aggregate_reading_preserves_actual_signal_event_time(self):
        aggregate = ORB.split("void AggregateReading", 1)[1].split("public:", 1)[0]
        self.assertIn("m_sessions[i].signalBar>m_reading.signalBar", aggregate)
        self.assertIn("m_reading.signalBar=m_sessions[i].signalBar", aggregate)
        self.assertNotIn("m_reading.signalBar=m_sessions[i].lastProcessedBar", aggregate)

    def test_engine_refreshes_using_server_time_and_symbol_point(self):
        self.assertIn("TimeTradeServer()", EA)
        self.assertIn("g_advancedSessionOrb.Update(_Symbol,orbServerTime,g_md.Point())", EA)


if __name__ == "__main__":
    unittest.main(verbosity=2)
