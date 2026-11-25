"""Source-contract tests for VWAP/ADX, overnight and twin continuation evidence.

These tests protect implementation wiring and attribution. They do not compile
MQL5, replay historical prices, or establish predictive value or profitability.
"""
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[1]
DEFS = (ROOT / "MQL5/Include/AutopsyX/Defs.mqh").read_text(encoding="utf-8-sig")
SCORER = (ROOT / "MQL5/Include/AutopsyX/SignalScore.mqh").read_text(encoding="utf-8-sig")
ENGINE = (ROOT / "MQL5/Include/AutopsyX/ContinuationIntelligence.mqh").read_text(encoding="utf-8-sig")
EA = (ROOT / "MQL5/Experts/AutopsyX/AutopsyX_FlipDemon_Extreme.mq5").read_text(encoding="utf-8-sig")


class ContinuationIntelligenceContractTests(unittest.TestCase):
    def test_engine_is_wired_into_existing_ea(self):
        self.assertIn('#include <AutopsyX/ContinuationIntelligence.mqh>', EA)
        self.assertIn('CContinuationIntelligence g_continuationIntelligence;', EA)
        self.assertIn('g_continuationIntelligence.Update(', EA)
        self.assertIn('AxApplyContinuationIntelligenceBonus(score);', EA)

    def test_adx_uses_closed_bar_buffers_and_configurable_strength_floor(self):
        self.assertIn('iADX(m_symbol,m_tf,m_adxPeriod)', ENGINE)
        self.assertIn('CopyBuffer(m_adxHandle,0,1,3,adx)', ENGINE)
        self.assertIn('CopyBuffer(m_adxHandle,1,1,3,plus)', ENGINE)
        self.assertIn('CopyBuffer(m_adxHandle,2,1,3,minus)', ENGINE)
        self.assertIn('adx[0]>=m_adxTrendThreshold', ENGINE)
        self.assertIn('plus[0]>minus[0]', ENGINE)
        self.assertIn('minus[0]>plus[0]', ENGINE)

    def test_vwap_pullback_requires_touch_rejection_and_directional_confirmation(self):
        for marker in (
            'bullTouch', 'bearTouch', 'bullResume', 'bearResume',
            'vwapTrend=="BULLISH"', 'vwapTrend=="BEARISH"',
            'adxTrend && bullishDI', 'adxTrend && bearishDI',
        ):
            with self.subTest(marker=marker):
                self.assertIn(marker, ENGINE)

    def test_overnight_bias_uses_completed_cross_midnight_window(self):
        self.assertIn('finish=today+(datetime)(endHour*3600)', ENGINE)
        self.assertIn('start=finish-86400+(datetime)(startHour*3600)', ENGINE)
        self.assertIn('CopyRates(m_symbol,PERIOD_M1,start,finish-1,session)', ENGINE)
        self.assertIn('if(copied<30) return(false)', ENGINE)
        self.assertIn('session[oldest].time>start+1800', ENGINE)
        self.assertIn('session[0].time<finish-1800', ENGINE)

    def test_twin_continuation_is_two_impulses_with_intervening_pullback(self):
        for marker in (
            'firstBull', 'pullbackBull', 'secondBull',
            'firstBear', 'pullbackBear', 'secondBear',
        ):
            with self.subTest(marker=marker):
                self.assertIn(marker, ENGINE)
        self.assertIn('secondBull && plus[0]>minus[0]', ENGINE)
        self.assertIn('secondBear && minus[0]>plus[0]', ENGINE)

    def test_all_continuation_bonus_fields_are_part_of_score_snapshot(self):
        fields = (
            'vwapPullbackBullBonus', 'vwapPullbackBearBonus',
            'overnightBiasBullBonus', 'overnightBiasBearBonus',
            'twinContinuationBullBonus', 'twinContinuationBearBonus',
        )
        for field in fields:
            with self.subTest(field=field):
                self.assertIn(field, DEFS)
                self.assertRegex(SCORER, rf's\.{field}\s*=\s*0\.0;')
                self.assertIn(f'score.{field}=', EA)

    def test_each_contribution_is_recorded_only_after_w1_d1_agreement(self):
        for field in (
            'vwapPullbackBullBonus', 'vwapPullbackBearBonus',
            'overnightBiasBullBonus', 'overnightBiasBearBonus',
            'twinContinuationBullBonus', 'twinContinuationBearBonus',
        ):
            line = next(x for x in EA.splitlines() if f'score.{field}=' in x)
            self.assertIn('g_w1Institutional.AllowsDirection', line)
            self.assertIn('g_d1Institutional.AllowsDirection', line)

    def test_contribution_weights_are_bounded(self):
        self.assertIn('AxClampD(InpVWAPPullbackScoreWeight,0.0,8.0)', EA)
        self.assertIn('AxClampD(InpOvernightBiasScoreWeight,0.0,5.0)', EA)
        self.assertIn('AxClampD(InpTwinContinuationScoreWeight,0.0,8.0)', EA)

    def test_continuation_engine_has_no_order_execution_authority(self):
        forbidden = ('OrderSend(', '.Buy(', '.Sell(', 'PositionOpen(', 'CTrade')
        for token in forbidden:
            with self.subTest(token=token):
                self.assertNotIn(token, ENGINE)

    def test_disabled_or_unavailable_engine_cannot_add_score(self):
        self.assertIn('if(!InpUseContinuationIntelligence || !g_regime.TradingAllowed()) return;', EA)
        self.assertIn('if(!r.available) return;', EA)


if __name__ == "__main__":
    unittest.main(verbosity=2)
