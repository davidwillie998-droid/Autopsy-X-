from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
UNIVERSE_FILE = REPO_ROOT / "MQL5" / "Include" / "AutopsyX" / "BrokerUniverse.mqh"


def test_broker_universe_discovers_symbols_from_connected_terminal():
    src = UNIVERSE_FILE.read_text(errors="replace")
    assert "SymbolsTotal(false)" in src
    assert "SymbolName(i,false)" in src
    assert "bool              Refresh(const bool select_all=false)" in src
    assert "bool              Get(const int index,SAxBrokerSymbol &out) const" in src


def test_synthetic_families_are_classified_before_fx():
    src = UNIVERSE_FILE.read_text(errors="replace")
    family_checks = [
        "RANGEBREAK,RANGE BREAK,RANGE_BREAK",
        "BOOM,CRASH",
        "JUMP",
        "STEP",
        "DRIFT,SWITCHING",
        "HYBRID",
        "VOLATILITY,VOL ",
    ]
    positions = [src.index(token) for token in family_checks]
    fx_position = src.index("// FX classification is deliberately conservative")
    assert all(pos < fx_position for pos in positions)
    for enum_name in (
        "AX_FAMILY_SYNTH_VOLATILITY",
        "AX_FAMILY_SYNTH_BOOM_CRASH",
        "AX_FAMILY_SYNTH_JUMP",
        "AX_FAMILY_SYNTH_STEP",
        "AX_FAMILY_SYNTH_RANGE_BREAK",
        "AX_FAMILY_SYNTH_DRIFT_SWITCH",
        "AX_FAMILY_SYNTH_HYBRID",
        "AX_FAMILY_SYNTH_OTHER",
    ):
        assert enum_name in src


def test_universe_rejects_symbols_with_incomplete_contract_metadata():
    src = UNIVERSE_FILE.read_text(errors="replace")
    assert "out.point<=0.0 || out.tick_size<=0.0" in src
    assert "out.volume_min<=0.0 || out.volume_max<out.volume_min" in src
    assert "out.volume_step<=0.0" in src
    assert "out.tradeable=false;" in src


def test_universe_discovery_does_not_execute_trades():
    src = UNIVERSE_FILE.read_text(errors="replace")
    forbidden = (".Buy(", ".Sell(", "OrderSend(", "OrderSendAsync(", ".PositionOpen(")
    assert not any(token in src for token in forbidden)
