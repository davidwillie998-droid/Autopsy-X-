"""Source-contract checks for completed-bar liquidity event classification."""
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[1]
LIQUIDITY = ROOT / "MQL5/Include/AutopsyX/Liquidity.mqh"
EA = ROOT / "MQL5/Experts/AutopsyX/AutopsyX_FlipDemon_Extreme.mq5"


class LiquidityEventClassificationTests(unittest.TestCase):
    def test_classifier_is_telemetry_only_and_has_explicit_outcomes(self):
        source = LIQUIDITY.read_text()
        for name in (
            "AX_LIQ_EVENT_UNCONFIRMED",
            "AX_LIQ_EVENT_REVERSAL_BULLISH",
            "AX_LIQ_EVENT_REVERSAL_BEARISH",
            "AX_LIQ_EVENT_CONTINUATION_BULLISH",
            "AX_LIQ_EVENT_CONTINUATION_BEARISH",
        ):
            self.assertIn(name, source)
        self.assertIn("This is telemetry, not an entry trigger or score override.", source)

    def test_reversal_requires_reclaim_displacement_and_choch_or_mss(self):
        source = LIQUIDITY.read_text()
        self.assertIn("m_bullRejectionConfirmed", source)
        self.assertIn("structureEvent==AX_STRUCT_CHOCH_BULLISH || structureEvent==AX_STRUCT_MSS_BULLISH", source)
        self.assertIn("m_bearRejectionConfirmed", source)
        self.assertIn("structureEvent==AX_STRUCT_CHOCH_BEARISH || structureEvent==AX_STRUCT_MSS_BEARISH", source)
        self.assertIn("close>m_bullSweepLevel && displacementPts>0.0 && isDisplacement", source)
        self.assertIn("close<m_bearSweepLevel && displacementPts<0.0 && isDisplacement", source)

    def test_continuation_requires_close_through_level_and_bos(self):
        source = LIQUIDITY.read_text()
        self.assertIn("close<m_bullSweepLevel && displacementPts<0.0 && isDisplacement", source)
        self.assertIn("structureEvent==AX_STRUCT_BOS_BEARISH", source)
        self.assertIn("close>m_bearSweepLevel && displacementPts>0.0 && isDisplacement", source)
        self.assertIn("structureEvent==AX_STRUCT_BOS_BULLISH", source)

    def test_ambiguous_opposing_sweeps_remain_unconfirmed(self):
        source = LIQUIDITY.read_text()
        self.assertIn("if(m_bullClassificationPending && m_bearClassificationPending)", source)
        body = source.split("if(m_bullClassificationPending && m_bearClassificationPending)", 1)[1].split(
            "if(m_bullClassificationPending)", 1
        )[0]
        self.assertIn("AX_LIQ_EVENT_UNCONFIRMED", body)
        self.assertIn("return; // opposing sweeps in one window are ambiguous", body)

    def test_closed_bar_snapshot_survives_legacy_tick_expiry(self):
        source = LIQUIDITY.read_text()
        self.assertIn("m_bullClassificationPending=true", source)
        self.assertIn("m_bearClassificationPending=true", source)
        self.assertIn("int classificationExpirySeconds=MathMax(120,tfSeconds*2)", source)
        self.assertIn("m_bullClassificationRejected", source)
        self.assertIn("m_bearClassificationRejected", source)
        self.assertIn("m_sweepExpirySeconds=120", source)

    def test_classification_runs_once_per_closed_bar_and_is_wired(self):
        source = LIQUIDITY.read_text()
        self.assertIn("closedBarTime==m_lastClassifiedBarTime", source)
        self.assertIn("m_lastClassifiedBarTime=closedBarTime", source)
        ea = EA.read_text()
        self.assertIn("g_liq.ClassifyClosedBar", ea)
        self.assertIn("iTime(_Symbol,InpRegimeTimeframe,1)", ea)
        self.assertIn("iClose(_Symbol,InpRegimeTimeframe,1)", ea)


if __name__ == "__main__":
    unittest.main()
