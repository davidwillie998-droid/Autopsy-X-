"""Static safety checks for the bounded multi-symbol analysis pool."""
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
POOL = ROOT / "MQL5/Include/AutopsyX/MultiSymbolAnalysisPool.mqh"


def source():
    return POOL.read_text(encoding="utf-8")


def test_pool_is_bounded_and_rejects_invalid_configuration():
    text = source()
    assert "AX_MAX_ANALYSIS_SLOTS 32" in text
    assert "max_symbols<1 || max_symbols>AX_MAX_ANALYSIS_SLOTS" in text
    assert "m_max_symbols=8" in text


def test_pool_uses_scanner_candidates_and_independent_slots():
    text = source()
    assert '#include "MarketScanner.mqh"' in text
    assert '#include "SymbolAnalysisSlot.mqh"' in text
    assert "scanner.Get(i,candidate)" in text
    assert "slot.Init(wanted[j],m_tf,m_min_score,m_min_gap)" in text


def test_best_candidate_is_analytical_not_execution_authority():
    text = source()
    assert "BestAnalyticalCandidate" in text
    assert "result.valid || result.action==AX_DIR_NONE" in text
    assert "NOT risk approval" in text
    lower = text.lower()
    for forbidden in ("ordersend(", "trade.buy(", "trade.sell(", "order_send"):
        assert forbidden not in lower


def test_pool_cleans_up_dynamic_slots():
    text = source()
    assert "delete m_slots[i]" in text
    assert "delete slot" in text
    assert "ClearSlots();" in text
