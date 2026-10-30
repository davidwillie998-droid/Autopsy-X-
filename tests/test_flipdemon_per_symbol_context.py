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
        ):
            self.assertIn(member, source)

    def test_all_market_reads_are_keyed_to_context_symbol(self):
        source = CONTEXT.read_text(encoding="utf-8")
        self.assertIn("m_market.Init(m_symbol)", source)
        self.assertIn("iTime(m_symbol,m_signalTimeframe,0)", source)
        self.assertIn("iTime(m_symbol,m_higherTimeframe,0)", source)
        self.assertIn("m_liquidity.RefreshHigherTimeframeLevels(m_symbol)", source)
        self.assertNotIn("_Symbol", source)

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


if __name__ == "__main__":
    unittest.main(verbosity=2)
