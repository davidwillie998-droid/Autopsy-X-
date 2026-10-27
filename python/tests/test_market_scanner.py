from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
SCANNER_FILE = REPO_ROOT / "MQL5" / "Include" / "AutopsyX" / "MarketScanner.mqh"


def test_scanner_fails_closed_on_invalid_limits_and_stale_quotes():
    src = SCANNER_FILE.read_text(errors="replace")
    assert "max_spread_percent<=0.0 || max_quote_age_seconds<=0" in src
    assert "(now-(datetime)tick.time)>max_quote_age_seconds" in src
    assert "spread_pct>max_spread_percent" in src


def test_scanner_uses_broker_metadata_and_only_supported_families():
    src = SCANNER_FILE.read_text(errors="replace")
    assert "meta.tradeable" in src
    assert "IsSupportedFamily(meta.family)" in src
    assert "meta.tick_size" in src
    assert "meta.volume_step" in src
    assert "require_selected && !meta.selected" in src


def test_scanner_orders_candidates_by_relative_spread_not_trade_signal():
    src = SCANNER_FILE.read_text(errors="replace")
    assert "SortByQuoteCost();" in src
    assert "spread_percent" in src
    assert "OrderSend(" not in src
    assert ".Buy(" not in src
    assert ".Sell(" not in src


def test_scanner_does_not_claim_to_authorize_or_execute_trades():
    src = SCANNER_FILE.read_text(errors="replace")
    assert "Does not score direction, authorize risk, or send orders." in src
    assert "bool              Get(const int index,SAxScanCandidate &out) const" in src
