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
        self.assertIn("m_bullClassificationRejected", source)
        self.assertIn("structureEvent==AX_STRUCT_CHOCH_BULLISH || structureEvent==AX_STRUCT_MSS_BULLISH", source)
        self.assertIn("m_bearClassificationRejected", source)
        self.assertIn("structureEvent==AX_STRUCT_CHOCH_BEARISH || structureEvent==AX_STRUCT_MSS_BEARISH", source)
        self.assertIn("close>m_bullClassificationLevel && displacementPts>0.0 && isDisplacement", source)
        self.assertIn("close<m_bearClassificationLevel && displacementPts<0.0 && isDisplacement", source)

    def test_continuation_requires_close_through_level_and_bos(self):
        source = LIQUIDITY.read_text()
        self.assertIn("close<m_bullClassificationLevel && displacementPts<0.0 && isDisplacement", source)
        self.assertIn("structureEvent==AX_STRUCT_BOS_BEARISH", source)
        self.assertIn("close>m_bearClassificationLevel && displacementPts>0.0 && isDisplacement", source)
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
        self.assertIn("iOpen(_Symbol,InpRegimeTimeframe,1)", ea)
        self.assertIn("iClose(_Symbol,InpRegimeTimeframe,1)", ea)

    def test_classifier_uses_signed_closed_bar_body_not_live_tick_momentum(self):
        ea = EA.read_text()
        self.assertIn(
            "double closedBarDisplacementPts=(liquidityClosedBarClose-liquidityClosedBarOpen)/liquidityPoint;",
            ea,
        )
        self.assertIn("g_structure.LastEventTime()==liquidityClosedBarTime", ea)
        self.assertIn("closedBarStructureEvent=g_structure.LastEvent()", ea)
        call = ea.split("g_liq.ClassifyClosedBar", 1)[1].split(");", 1)[0]
        self.assertIn("closedBarDisplacementPts", call)
        self.assertNotIn("g_mom.DisplacementPts()", call)


    @staticmethod
    def classify_reference(
        side, close, level, displacement, is_displacement, rejected,
        structure_event, opposing=False, expired=False,
    ):
        """Behavioral specification for the MQL5 classifier, not an MT5 runtime."""
        if expired:
            return "NONE"
        if opposing:
            return "UNCONFIRMED"
        if side == "sell_side_swept":
            if close < level and displacement < 0 and is_displacement and structure_event == "BOS_BEARISH":
                return "CONTINUATION_BEARISH"
            if close > level and displacement > 0 and is_displacement and rejected and structure_event in ("CHOCH_BULLISH", "MSS_BULLISH"):
                return "REVERSAL_BULLISH"
        elif side == "buy_side_swept":
            if close > level and displacement > 0 and is_displacement and structure_event == "BOS_BULLISH":
                return "CONTINUATION_BULLISH"
            if close < level and displacement < 0 and is_displacement and rejected and structure_event in ("CHOCH_BEARISH", "MSS_BEARISH"):
                return "REVERSAL_BEARISH"
        return "UNCONFIRMED"

    def test_scenario_matrix_confirms_only_complete_structural_evidence(self):
        cases = [
            ("sell_side_swept", 99, 100,  -8, True,  False, "BOS_BEARISH", "CONTINUATION_BEARISH"),
            ("buy_side_swept",  101,100,   8, True,  False, "BOS_BULLISH", "CONTINUATION_BULLISH"),
            ("sell_side_swept", 101,100,   8, True,  True,  "CHOCH_BULLISH", "REVERSAL_BULLISH"),
            ("buy_side_swept",   99,100,  -8, True,  True,  "MSS_BEARISH", "REVERSAL_BEARISH"),
            ("sell_side_swept", 101,100,   8, True,  False, "CHOCH_BULLISH", "UNCONFIRMED"),
            ("buy_side_swept",   99,100,  -8, False, True,  "CHOCH_BEARISH", "UNCONFIRMED"),
            ("sell_side_swept", 100,100,   8, True,  True,  "CHOCH_BULLISH", "UNCONFIRMED"),
            ("buy_side_swept",  101,100,  -8, True,  True,  "MSS_BEARISH", "UNCONFIRMED"),
        ]
        for side, close, level, displacement, impulse, rejected, event, expected in cases:
            with self.subTest(side=side, event=event, expected=expected):
                self.assertEqual(
                    self.classify_reference(side, close, level, displacement, impulse, rejected, event),
                    expected,
                )

    def test_opposing_and_expired_sweeps_never_receive_directional_labels(self):
        args = ("sell_side_swept", 101, 100, 8, True, True, "CHOCH_BULLISH")
        self.assertEqual(self.classify_reference(*args, opposing=True), "UNCONFIRMED")
        self.assertEqual(self.classify_reference(*args, expired=True), "NONE")

    def test_scenario_contract_is_present_in_mql5_classifier(self):
        source = LIQUIDITY.read_text()
        required = (
            "close<m_bullClassificationLevel && displacementPts<0.0 && isDisplacement",
            "structureEvent==AX_STRUCT_BOS_BEARISH",
            "close>m_bearClassificationLevel && displacementPts>0.0 && isDisplacement",
            "structureEvent==AX_STRUCT_BOS_BULLISH",
            "m_bullClassificationRejected",
            "m_bearClassificationRejected",
            "structureEvent==AX_STRUCT_CHOCH_BULLISH || structureEvent==AX_STRUCT_MSS_BULLISH",
            "structureEvent==AX_STRUCT_CHOCH_BEARISH || structureEvent==AX_STRUCT_MSS_BEARISH",
            "if(m_bullClassificationPending && m_bearClassificationPending)",
            "classificationExpirySeconds",
        )
        for fragment in required:
            with self.subTest(fragment=fragment):
                self.assertIn(fragment, source)


if __name__ == "__main__":
    unittest.main()
