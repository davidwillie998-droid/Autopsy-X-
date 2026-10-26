"""Static safety checks for the first account-wide portfolio gate."""
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
GATE = ROOT / "MQL5/Include/AutopsyX/PortfolioRiskGate.mqh"


def source():
    return GATE.read_text(encoding="utf-8")


def test_gate_is_conservative_and_bounded():
    text = source()
    assert "m_max_trade_risk_pct=0.5" in text
    assert "m_max_margin_usage_pct=30.0" in text
    assert "max_trade_risk_pct>2.0" in text
    assert "m_require_flat_account && PositionsTotal()>0" in text
    assert "OrdersTotal()>0" in text


def test_gate_requires_stop_loss_and_checks_loss_side():
    text = source()
    assert "stop_loss<=0.0" in text
    assert "Stop-loss is not on the loss side of entry" in text
    assert "OrderCalcProfit" in text
    assert "risk_pct>m_max_trade_risk_pct" in text


def test_gate_checks_broker_volume_and_projected_margin():
    text = source()
    assert "SYMBOL_VOLUME_MIN" in text
    assert "SYMBOL_VOLUME_MAX" in text
    assert "SYMBOL_VOLUME_STEP" in text
    assert "OrderCalcMargin" in text
    assert "projected_usage>=m_max_margin_usage_pct" in text


def test_gate_cannot_send_orders():
    text = source().lower()
    for forbidden in ("ordersend(", "trade.buy(", "trade.sell(", "order_send"):
        assert forbidden not in text
