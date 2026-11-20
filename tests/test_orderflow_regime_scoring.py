"""Source-contract tests for regime-conditioned order-flow evidence weights.

These tests verify the MQL5 decision contract, not profitability or native compilation.
"""
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[1]
EA = ROOT / "MQL5/Experts/AutopsyX/AutopsyX_FlipDemon_Extreme.mq5"
ORDERFLOW = ROOT / "MQL5/Include/AutopsyX/OrderFlow.mqh"


class RegimeConditionedOrderFlowTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.source = EA.read_text()


    def test_orderflow_invalidates_rolling_state_before_refresh(self):
        source = ORDERFLOW.read_text()
        update = source.split("void              Update(const CMarketData &md)", 1)[1].split(
            "double            SessionCvd", 1
        )[0]
        reset = update.index("m_windowDelta=0; m_windowVolume=0; m_imbalanceRatio=0; m_priceRangePts=0;")
        sample_read = update.index("md.GetSample(0,newest)")
        self.assertLess(reset, sample_read)
        for flag in ("m_bullAbsorption=false", "m_bearAbsorption=false",
                     "m_bullCvdDivergence=false", "m_bearCvdDivergence=false"):
            self.assertIn(flag, update[:sample_read])

    def test_orderflow_rejects_incomplete_rolling_windows(self):
        source = ORDERFLOW.read_text()
        update = source.split("void              Update(const CMarketData &md)", 1)[1].split(
            "double            SessionCvd", 1
        )[0]
        self.assertIn("if(n<5) return;", update)
        self.assertIn("if(!md.GetSample(i,t)) return;", update)
        self.assertIn("if(validSamples!=n || hi<=-DBL_MAX || lo>=DBL_MAX) return;", update)
        self.assertNotIn("if(!md.GetSample(i,t)) continue;", update)

    def test_regime_weight_function_covers_all_existing_regimes(self):
        body = self.source.split(
            "double AxOrderFlowRegimeMultiplier(const ENUM_AX_DIR direction)", 1
        )[1].split("void AxApplyOrderFlowBonus", 1)[0]
        for regime in (
            "AX_REGIME_STRONG_TREND", "AX_REGIME_TREND", "AX_REGIME_BREAKOUT",
            "AX_REGIME_RANGE", "AX_REGIME_MEAN_REVERSION", "AX_REGIME_HIGH_VOL",
            "AX_REGIME_LOW_VOL", "AX_REGIME_CHAOTIC", "AX_REGIME_UNSAFE",
        ):
            self.assertIn(regime, body)

    def test_trend_weights_distinguish_aligned_and_countertrend_flow(self):
        body = self.source.split(
            "double AxOrderFlowRegimeMultiplier(const ENUM_AX_DIR direction)", 1
        )[1].split("void AxApplyOrderFlowBonus", 1)[0]
        self.assertIn("g_regime.Slope()>0.0", body)
        self.assertIn("g_regime.Slope()<0.0", body)
        self.assertIn("? 1.0 : 0.35", body)
        self.assertIn("? 0.85 : 0.45", body)
        self.assertIn("? 0.90 : 0.30", body)
        self.assertIn("return(0.30)", body)

    def test_all_flow_evidence_is_scaled_before_it_changes_scores(self):
        body = self.source.split("void AxApplyOrderFlowBonus(SAxScore &score)", 1)[1]
        self.assertIn("buyBonus*=buyRegimeMultiplier", body)
        self.assertIn("sellBonus*=sellRegimeMultiplier", body)
        self.assertLess(body.index("buyBonus*=buyRegimeMultiplier"),
                        body.index("score.buyScore"))
        self.assertLess(body.index("sellBonus*=sellRegimeMultiplier"),
                        body.index("score.sellScore"))

    def test_regime_conditioning_is_not_an_order_trigger_or_risk_override(self):
        body = self.source.split(
            "double AxOrderFlowRegimeMultiplier(const ENUM_AX_DIR direction)", 1
        )[1].split("void AxApplyPremiumDiscountScoreBonus", 1)[0]
        self.assertNotIn("OrderSend", body)
        self.assertNotIn("CTrade", body)
        self.assertIn("if(!g_regime.TradingAllowed()) return", body)
        self.assertIn("AX_REGIME_UNSAFE", body)


if __name__ == "__main__":
    unittest.main()
