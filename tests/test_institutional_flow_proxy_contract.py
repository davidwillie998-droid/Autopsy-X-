"""Source contracts for the existing order-flow engine's institutional-behaviour proxies.

These tests verify wiring and explicit data provenance. They do not establish
institutional identity, profitability, or native MetaTrader compilation.
"""
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[1]
DEFS = (ROOT / "MQL5/Include/AutopsyX/Defs.mqh").read_text(encoding="utf-8-sig")
MARKET_DATA = (ROOT / "MQL5/Include/AutopsyX/MarketData.mqh").read_text(encoding="utf-8-sig")
ORDER_FLOW = (ROOT / "MQL5/Include/AutopsyX/OrderFlow.mqh").read_text(encoding="utf-8-sig")
DASHBOARD = (ROOT / "MQL5/Include/AutopsyX/Dashboard.mqh").read_text(encoding="utf-8-sig")
EA = (ROOT / "MQL5/Experts/AutopsyX/AutopsyX_FlipDemon_Extreme.mq5").read_text(encoding="utf-8-sig")


class InstitutionalFlowProxyContracts(unittest.TestCase):
    def test_tick_volume_provenance_is_explicit(self):
        for token in ("AX_VOLUME_SOURCE_TICK_COUNT", "AX_VOLUME_SOURCE_TICK_VOLUME",
                      "AX_VOLUME_SOURCE_REAL", "int      volumeSource"):
            self.assertIn(token, DEFS)
        self.assertIn("m_ticks[m_head].volumeSource=AX_VOLUME_SOURCE_REAL", MARKET_DATA)
        self.assertIn("m_ticks[m_head].volumeSource=AX_VOLUME_SOURCE_TICK_VOLUME", MARKET_DATA)
        self.assertIn("m_ticks[m_head].volumeSource=AX_VOLUME_SOURCE_TICK_COUNT", MARKET_DATA)

    def test_quote_direction_is_not_mislabeled_as_aggressor_data(self):
        self.assertIn("Direction is inferred from accepted mid-price changes", ORDER_FLOW)
        self.assertIn("not signed exchange volume", ORDER_FLOW)
        self.assertIn("QUOTE_DIRECTION", ORDER_FLOW)

    def test_persistence_uses_multiple_chronological_buckets(self):
        self.assertIn("#define AX_OF_PERSISTENCE_BUCKETS 5", ORDER_FLOW)
        self.assertIn("m_validPersistenceBuckets>=4", ORDER_FLOW)
        self.assertIn("alignedBuckets>=4", ORDER_FLOW)
        self.assertIn("m_flowPersistence>=80.0", ORDER_FLOW)

    def test_absorption_requires_pressure_and_limited_directional_progress(self):
        self.assertIn("alignedProgressPts=dominantSign*m_windowNetMovePts", ORDER_FLOW)
        self.assertIn("m_absorptionStrength>=35.0", ORDER_FLOW)
        self.assertNotIn("rangeStalled", ORDER_FLOW)

    def test_parent_order_label_is_only_a_behavioural_proxy(self):
        self.assertIn("m_parentOrderPersistenceProxy", ORDER_FLOW)
        self.assertIn("ParentOrderPersistenceProxy", ORDER_FLOW)
        self.assertIn("not prove that one institution or one parent order generated the observed sequence", ORDER_FLOW)
        self.assertIn("PERSISTENT FLOW PROXY", DASHBOARD)

    def test_score_is_adjusted_for_directional_sample_coverage(self):
        self.assertIn("m_directionalCoveragePct/100.0", ORDER_FLOW)
        self.assertIn("score+=m_flowPersistence*0.25*coverage", ORDER_FLOW)

    def test_mixed_volume_sources_use_comparable_tick_weights(self):
        self.assertIn("bool mixedVolumeSource=(sourceClasses>1)", ORDER_FLOW)
        self.assertIn("mixedVolumeSource ? 1.0", ORDER_FLOW)
        self.assertIn("Homogeneous windows retain their native feed-volume weighting", ORDER_FLOW)
        self.assertIn("Session CVD and the footprint's per-tick input use unit tick weights", ORDER_FLOW)

    def test_volume_provenance_is_not_misrepresented_as_quality(self):
        self.assertNotIn("m_volumeSourceGradePct", ORDER_FLOW)
        self.assertNotIn("VolumeSourceGradePct", ORDER_FLOW)
        self.assertIn("m_realVolumeSharePct", ORDER_FLOW)
        self.assertIn("m_tickVolumeSharePct", ORDER_FLOW)
        self.assertIn("m_tickCountProxySharePct", ORDER_FLOW)
        self.assertIn("These shares describe feed composition, not data quality", ORDER_FLOW)

    def test_existing_engine_is_reused_and_dashboard_is_wired(self):
        self.assertIn("COrderFlowEngine      g_orderFlow", EA)
        self.assertIn("g_orderFlow.FlowPersistence()", EA)
        self.assertIn("g_orderFlow.VolumeEvidenceLabel()", EA)
        self.assertNotIn("CInstitutionalOrderFlowEngine", EA)


if __name__ == "__main__":
    unittest.main(verbosity=2)
