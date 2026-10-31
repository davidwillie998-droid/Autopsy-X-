"""Source-contract tests for isolated per-symbol analysis contexts.

The reference test demonstrates independent state ownership. It does not execute
MQL5 indicators, broker feeds or the MetaTrader runtime.
"""
from dataclasses import dataclass, field
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[1]
CONTEXT = ROOT / "MQL5/Include/AutopsyX/PerSymbolAnalysisContext.mqh"


@dataclass
class ContextReference:
    symbol: str
    ticks: list = field(default_factory=list)
    score: float = 0.0
    regime: str = "UNSAFE"


class PerSymbolContextReferenceTests(unittest.TestCase):
    def test_two_symbols_keep_market_and_signal_state_separate(self):
        gold = ContextReference("XAUUSD")
        yen = ContextReference("GBPJPY")
        gold.ticks.extend([2300.1, 2300.4, 2300.8])
        yen.ticks.extend([191.2, 191.1])
        gold.score = 82.0
        yen.score = 63.0
        gold.regime = "TREND"
        yen.regime = "RANGE"
        self.assertEqual(gold.ticks, [2300.1, 2300.4, 2300.8])
        self.assertEqual(yen.ticks, [191.2, 191.1])
        self.assertNotEqual(gold.score, yen.score)
        self.assertNotEqual(gold.regime, yen.regime)

    def test_context_owns_independent_market_and_signal_engines(self):
        source = CONTEXT.read_text(encoding="utf-8")
        for member in (
            "CMarketData            m_market;",
            "CMomentumEngine        m_momentum;",
            "CMicrostructureEngine  m_microstructure;",
            "CLiquidityEngine       m_liquidity;",
            "CRegimeEngine          m_regime;",
            "CRegimeEngine          m_higherRegime;",
            "CSignalScorer          m_scorer;",
            "COrderFlowEngine       m_orderFlow;",
            "CFootprintEngine       m_footprint;",
            "CVolumeProfileEngine   m_volumeProfile;",
            "CVWAPEngine            m_vwap;",
            "CHeatmapEngine         m_heatmap;",
            "CSniperEngine          m_sniper;",
        ):
            self.assertIn(member, source)

    def test_all_market_reads_are_keyed_to_context_symbol(self):
        source = CONTEXT.read_text(encoding="utf-8")
        self.assertIn("m_market.Init(m_symbol)", source)
        self.assertIn("iTime(m_symbol,m_signalTimeframe,0)", source)
        self.assertIn("iTime(m_symbol,m_higherTimeframe,0)", source)
        self.assertIn("m_liquidity.RefreshHigherTimeframeLevels(m_symbol)", source)
        self.assertIn("iTime(m_symbol,m_footprintTimeframe,0)", source)
        self.assertIn("m_orderFlow.Update(m_market)", source)
        self.assertIn("m_footprint.OnTick(footprintBar,m_market.CurrentMid()", source)
        self.assertIn("m_volumeProfile.Init(m_symbol,120,10.0,m_market.Point(),m_signalTimeframe)", source)
        self.assertIn("m_vwap.GetVWAP(m_symbol,m_signalTimeframe)", source)
        self.assertIn("iClose(m_symbol,m_signalTimeframe,1)", source)
        self.assertIn("m_volumeProfile.Refresh()", source)
        self.assertIn("m_vwap.ClassifyVWAPTrend", source)
        self.assertNotIn("_Symbol", source)

    def test_volume_profile_and_vwap_are_exposed_as_context_local_reads(self):
        source = CONTEXT.read_text(encoding="utf-8")
        for accessor in (
            "VolumeProfilePOC", "VolumeProfileVAH", "VolumeProfileVAL",
            "VolumeProfileValid", "VWAPValue", "VWAPTrend", "VWAPAligned",
        ):
            self.assertIn(accessor, source)

    def test_heatmap_and_sniper_are_context_owned_and_symbol_scaled(self):
        source = CONTEXT.read_text(encoding="utf-8")
        self.assertIn("m_heatmap.Init(m_symbol)", source)
        self.assertIn("m_heatmap.Update(m_market.CurrentBid(),m_market.CurrentAsk()", source)
        self.assertIn("m_heatmapRangePoints,m_market.Point()", source)
        self.assertIn("sniperPullbackPoints*m_market.Point()", source)
        self.assertIn("sniperResumePoints*m_market.Point()", source)
        self.assertIn("sniperMaxChasePoints*m_market.Point()", source)
        self.assertIn("m_sniper.Arm(direction,referencePrice)", source)
        self.assertIn("m_sniper.OnTick(m_market.CurrentMid(),expiredOut)", source)
        self.assertIn("void RefreshHeatmap(void)", source)
        self.assertIn("bool UpdateSniper(bool &expiredOut)", source)
        self.assertNotIn("_Symbol", source)

    def test_adaptive_flip_is_context_owned_and_account_peak_is_shared(self):
        source = CONTEXT.read_text(encoding="utf-8")
        engine = (ROOT / "MQL5/Include/AutopsyX/AdaptiveFlipEngine.mqh").read_text(encoding="utf-8")
        self.assertIn('#include "AdaptiveFlipEngine.mqh"', source)
        self.assertIn("CAdaptiveFlipEngine    m_adaptiveFlip;", source)
        self.assertIn("void ConfigureAdaptiveFlip(", source)
        self.assertIn("void InitAdaptiveFlip(const ulong magic)", source)
        self.assertIn("bool EvaluateAdaptiveFlip(", source)
        self.assertIn("m_adaptiveFlip.OnTickHousekeeping()", source)
        self.assertIn("symbolStats", source)
        self.assertIn("m_symbol,direction,lots,point,m_market.TickSize(),m_market.TickValue()", source)
        self.assertIn("InitAccountScoped(const ulong magic)", engine)
        self.assertIn("AXFDX_AFE_PeakEquity_ACCOUNT_%I64d_%I64u", engine)
        self.assertIn("AccountInfoInteger(ACCOUNT_LOGIN)", engine)
        self.assertNotIn("m_adaptiveFlip.Init(m_symbol", source)

    def test_optional_heatmap_and_context_reset_are_safe(self):
        source = CONTEXT.read_text(encoding="utf-8")
        heatmap = (ROOT / "MQL5/Include/AutopsyX/Heatmap.mqh").read_text(encoding="utf-8")
        self.assertIn("continuing without DOM", source)
        self.assertIn("m_heatmap.Deinit()", source)
        self.assertIn("m_sniper.Reset()", source)
        self.assertIn("m_available=false", heatmap)
        self.assertIn("m_prevCount=0", heatmap)
    def test_base_score_is_not_mislabeled_as_fully_qualified_candidate(self):
        source = CONTEXT.read_text(encoding="utf-8")
        self.assertIn("EvaluateBaseScore", source)
        self.assertIn("This is the independent base score only", source)
        self.assertNotIn("SubmitQualifiedCandidate", source)
        self.assertIn("must be applied by the owning per-symbol pipeline", source)

    def test_lifecycle_releases_indicator_handles_and_clears_tick_state(self):
        source = CONTEXT.read_text(encoding="utf-8")
        self.assertIn("m_regime.Deinit()", source)
        self.assertIn("m_higherRegime.Deinit()", source)
        self.assertIn("m_market.Reset()", source)
        self.assertIn("m_momentum.Clear()", source)
        self.assertIn("m_orderFlow.Clear()", source)
        self.assertIn("m_footprint.Clear()", source)
        self.assertIn("m_vwapValue=-1.0", source)
        self.assertIn("m_vwapTrend=\"NEUTRAL\"", source)


if __name__ == "__main__":
    unittest.main(verbosity=2)
