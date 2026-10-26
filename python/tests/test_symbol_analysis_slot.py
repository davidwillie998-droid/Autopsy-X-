"""Static safety checks for the scan-only per-symbol analysis slot."""
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SLOT = ROOT / "MQL5/Include/AutopsyX/SymbolAnalysisSlot.mqh"


def source():
    return SLOT.read_text(encoding="utf-8")


def test_slot_owns_independent_per_symbol_engines():
    text = source()
    for engine in (
        "CMarketData", "CMomentumEngine", "CMicrostructureEngine",
        "CLiquidityEngine", "CRegimeEngine", "CSignalScorer",
    ):
        assert engine in text
    assert "bool              Init(const string symbol" in text
    assert "m_symbol=symbol" in text


def test_analysis_slot_fails_closed_without_valid_data():
    text = source()
    assert "if(!m_md.OnTickUpdate())" in text
    assert "m_last.action=m_last.valid ? score.action : AX_DIR_NONE" in text
    assert "m_regime.TradingAllowed()" in text
    assert "m_md.Count()>=5" in text


def test_analysis_slot_does_not_authorize_or_send_orders():
    text = source().lower()
    forbidden = (
        "ordersend(", "buy(", "sell(", "positionopen(", "order_send",
        "trade.buy(", "trade.sell(",
    )
    assert not any(token in text for token in forbidden)
    assert "analysis authorization" in text or "execution authorization" in text


def test_each_slot_uses_symbol_specific_market_data_and_regime():
    text = source()
    assert "m_md.Init(m_symbol)" in text
    assert "m_regime.Init(m_symbol,m_tf)" in text
    assert "m_liquidity.Init(m_symbol,m_tf)" in text
    assert "m_liquidity.RefreshHigherTimeframeLevels(m_symbol)" in text
