"""Source-contract tests for deterministic FlipDemon score evidence.

These tests verify source wiring and score decomposition only. They do not
compile MQL5, replay market data, or establish predictive value/profitability.
"""
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[1]
DEFS = (ROOT / "MQL5/Include/AutopsyX/Defs.mqh").read_text(encoding="utf-8-sig")
SCORER = (ROOT / "MQL5/Include/AutopsyX/SignalScore.mqh").read_text(encoding="utf-8-sig")
EA = (ROOT / "MQL5/Experts/AutopsyX/AutopsyX_FlipDemon_Extreme.mq5").read_text(encoding="utf-8-sig")


class FlipDemonScoreEvidenceContractTests(unittest.TestCase):
    def test_score_record_contains_component_level_evidence(self):
        required = (
            "microBullScore", "microBearScore",
            "liquidityBullScore", "liquidityBearScore",
            "momentumBullScore", "momentumBearScore",
            "regimeMultiplier", "preBonusBuyScore", "preBonusSellScore",
            "orderFlowBullBonus", "orderFlowBearBonus",
            "scoreGap", "minimumScoreToAct", "minimumGapToAct",
        )
        for field in required:
            with self.subTest(field=field):
                self.assertIn(field, DEFS)

    def test_base_scorer_initializes_all_evidence_fields_on_every_evaluation(self):
        for field in (
            "microBullScore", "microBearScore",
            "liquidityBullScore", "liquidityBearScore",
            "momentumBullScore", "momentumBearScore",
            "orderFlowBullBonus", "orderFlowBearBonus",
            "scoreGap", "minimumScoreToAct", "minimumGapToAct",
        ):
            with self.subTest(field=field):
                self.assertRegex(SCORER, rf"s\.{field}\s*=")
        self.assertIn("if(!regime.TradingAllowed())", SCORER)
        blocked = SCORER.split("if(!regime.TradingAllowed())", 1)[1].split("double microBull", 1)[0]
        self.assertIn("s.buyScore=0", blocked)
        self.assertIn("s.sellScore=0", blocked)
        self.assertIn("s.action=AX_DIR_NONE", blocked)

    def test_base_score_decomposition_matches_existing_weighted_formula(self):
        self.assertIn("m_wMicro*microBull + m_wLiquidity*liqBull + m_wMomentum*momBull", SCORER)
        self.assertIn("m_wMicro*microBear + m_wLiquidity*liqBear + m_wMomentum*momBear", SCORER)
        self.assertIn("s.preBonusBuyScore=buy;", SCORER)
        self.assertIn("s.preBonusSellScore=sell;", SCORER)
        self.assertIn("s.regimeMultiplier=regime.AggressionMultiplier();", SCORER)

    def test_order_flow_bonus_is_recorded_without_changing_additive_model(self):
        self.assertIn("score.orderFlowBullBonus=buyBonus;", EA)
        self.assertIn("score.orderFlowBearBonus=sellBonus;", EA)
        self.assertIn("score.buyScore  = AxClampD(score.preBonusBuyScore+buyBonus,0,100);", EA)
        self.assertIn("score.sellScore = AxClampD(score.preBonusSellScore+sellBonus,0,100);", EA)
        self.assertIn("score.scoreGap=gap;", EA)

    def test_confidence_is_explicitly_a_score_gap_heuristic(self):
        self.assertIn("s.confidence = AxClampD(gap*1.15,0,100);", SCORER)
        self.assertIn("score.confidence = AxClampD(gap*1.15,0,100);", EA)
        self.assertIn("confidence;           // heuristic score-separation measure, NOT win probability", DEFS)

    def test_action_requires_both_directional_score_and_separation_thresholds(self):
        self.assertIn("if(gap>=m_minGapToAct)", SCORER)
        self.assertIn("buy>=m_minScoreToAct", SCORER)
        self.assertIn("sell>=m_minScoreToAct", SCORER)
        self.assertIn("if(gap>=InpMinGapToAct)", EA)
        self.assertIn("score.buyScore>=InpMinScoreToAct", EA)
        self.assertIn("score.sellScore>=InpMinScoreToAct", EA)


if __name__ == "__main__":
    unittest.main(verbosity=2)
